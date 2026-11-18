// Ported from native-ios/TEGNALTests/StudyTests.swift. Dart takes a seeded `Random` where
// Swift takes a `SplitMix64` generator, a `utcOffset` where Swift takes a `Calendar`, and the
// fixture and stub server instead of `StudyURLProtocol`. The live-server test is not ported.

import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:math';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:tegnal/core/booru/booru_backup.dart';
import 'package:tegnal/core/booru/booru_browser.dart';
import 'package:tegnal/core/booru/booru_client.dart';
import 'package:tegnal/core/booru/booru_fixture_source.dart';
import 'package:tegnal/core/booru/booru_models.dart';
import 'package:tegnal/core/booru/booru_store.dart';
import 'package:tegnal/core/content/content_transport.dart';
import 'package:tegnal/core/storage/app_database.dart';
import 'package:tegnal/core/study/study_dtext.dart';
import 'package:tegnal/core/study/study_engine.dart';
import 'package:tegnal/core/study/study_models.dart';
import 'package:tegnal/core/study/study_session.dart';
import 'package:tegnal/core/study/study_store.dart';
import 'package:tegnal/core/support/preferences.dart';
import 'package:tegnal/core/sync/library_sync_adapter.dart';
import 'package:tegnal/core/sync/library_sync_record.dart';

import '../content/content_test_support.dart';

const utc = Duration.zero;
final dan = BooruServer(id: 'test-dan', name: 'Test', baseURL: 'https://example.com/booru', engine: BooruEngine.danbooru);
final gelbooru = BooruServer(id: 'test-gel', name: 'Gel', baseURL: 'https://gel.example.com', engine: BooruEngine.gelbooru);
final gelbooruWebsite = BooruServer(id: 'test-gel-site', name: 'Gel', baseURL: 'https://gelbooru.com', engine: BooruEngine.gelbooru);
final moebooru = BooruServer(id: 'test-moe', name: 'Moe', baseURL: 'https://moe.example.com', engine: BooruEngine.moebooru);

DateTime date(int year, int month, int day, {int hour = 12}) => DateTime.utc(year, month, day, hour);

StudyProgress due(String tag, DateTime now, {required int daysAgo}) => StudyProgress(
  tag: tag,
  step: 1,
  due: now.subtract(Duration(days: daysAgo)),
  correct: 1,
);

StudyTagInfo tagInfo(String name, {int? count}) => StudyTagInfo(
  name: name,
  count: count,
  category: 0,
  wiki: StudyWiki(title: name, body: 'body', otherNames: const ['x']),
  related: const [StudyRelatedTag(name: 'other', category: 0, count: 3, frequency: 0.5)],
  fetched: DateTime.fromMillisecondsSinceEpoch(DateTime.now().millisecondsSinceEpoch ~/ 1000 * 1000),
  complete: true,
);

BooruPost post(int id, List<String> tags, {String ext = 'png'}) => BooruFixtureSource.post(id, dan, tags: tags)..fileExtension = ext;

StudyTag plainTag(String name, {List<String>? confusable}) => StudyTag(name: name, ko: name, ja: name, note: {'en': name}, confusable: confusable);

/// Eight tags in one unit and three in another, for choosing rounds.
StudyCurriculum roundCurriculum() => StudyCurriculum(
  units: [
    StudyUnit(
      id: 'r1',
      title: const {'en': 'R1'},
      summary: const {'en': ''},
      groups: [
        StudyGroup(id: 'r1.a', title: const {'en': 'A'}, tags: [for (var i = 1; i <= 8; i++) plainTag('t$i')]),
      ],
    ),
    StudyUnit(
      id: 'r2',
      title: const {'en': 'R2'},
      summary: const {'en': ''},
      groups: [
        StudyGroup(id: 'r2.a', title: const {'en': 'B'}, tags: [for (var i = 1; i <= 3; i++) plainTag('w$i')]),
      ],
    ),
  ],
);
StudyEngine roundEngine() => StudyEngine(curriculum: roundCurriculum());

/// An exclusive group, a loose group and an abstract group, for building questions.
StudyCurriculum tinyCurriculum() => StudyCurriculum(
  units: [
    StudyUnit(
      id: 'u1',
      title: const {'en': 'U1'},
      summary: const {'en': ''},
      groups: [
        StudyGroup(
          id: 'g1',
          title: const {'en': 'Shot'},
          exclusive: true,
          tags: [
            plainTag('s1', confusable: const ['m1']),
            plainTag('s2'),
            plainTag('s3'),
            plainTag('s4'),
          ],
        ),
        StudyGroup(id: 'g2', title: const {'en': 'Misc'}, tags: [plainTag('m1'), plainTag('m2'), plainTag('m3')]),
      ],
    ),
    StudyUnit(
      id: 'u2',
      title: const {'en': 'U2'},
      summary: const {'en': ''},
      groups: [
        StudyGroup(
          id: 'g3',
          title: const {'en': 'Meaning'},
          exclusive: true,
          visual: false,
          tags: [plainTag('x1'), plainTag('x2'), plainTag('x3'), plainTag('x4')],
        ),
      ],
    ),
  ],
);
StudyEngine tinyEngine() => StudyEngine(curriculum: tinyCurriculum());
StudyTag tinyTag(String name) => tinyCurriculum().tag(name) ?? plainTag(name);

List<String> describe(List<StudyBlock> blocks) => [
  for (final block in blocks)
    switch (block) {
      StudyHeading(:final text) => 'h:$text',
      StudyParagraph(:final text) => 'p:$text',
      StudyBullet(:final level, :final text) => 'b$level:$text',
    },
];

List<({String text, String? tag})> links(List<StudySpan> spans) => [
  for (final span in spans)
    if (span.tag != null) (text: span.text, tag: span.tag),
];

String plainText(List<StudySpan> spans) => spans.map((span) => span.text).join();

Matcher unsupported() => isA<BooruError>().having((error) => error.kind, 'kind', BooruErrorKind.unsupported);

/// `mocked { request in (status, body) }`: a client whose network is [handler], and what it was asked.
(BooruClient, FixtureFetcher) mocked(FutureOr<(int, String)> Function(HttpExchange request) handler) {
  final fetcher = FixtureFetcher((request) async {
    final (status, body) = await handler(request);
    return FixtureReply.text(status, body);
  });
  return (BooruClient(fetcher: fetcher, credentials: MemoryCredentialStore(), session: BooruBrowserSession(), poolRequestDelay: Duration.zero), fetcher);
}

Map<String, String> query(HttpExchange request) => request.url.queryParameters;

/// Answers a Danbooru tag search with one row per asked name, each with a count of its position.
(int, String) tagsReply(HttpExchange request) {
  final asked = (query(request)['search[name_comma]'] ?? '').split(',').where((name) => name.isNotEmpty).toList();
  return (
    200,
    jsonEncode([
      for (final (index, name) in asked.indexed) {'name': name, 'post_count': index + 1, 'category': 0},
    ]),
  );
}

/// Answers every tag with a few still pictures that carry only that tag, immediately.
class StudyFakeSource with BooruTagStudyUnsupported implements BooruProviding {
  StudyFakeSource({this.failing = false});
  final bool failing;

  @override
  Future<BooruBatch> posts(BooruServer server, String query, int page) async {
    if (failing) throw const NetworkErrorForTests();
    final base = query.runes.fold<int>(0, (hash, rune) => (hash * 31 + rune) % 100000) * 10;
    return BooruBatch(
      posts: [
        for (var index = 0; index < 5; index++) BooruFixtureSource.post(base + index, server, tags: [query]),
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

class NetworkErrorForTests implements Exception {
  const NetworkErrorForTests();
}

/// A source that answers tag pages, counting how often it is asked.
class StudyPagesSource extends StudyFakeSource with BooruTagStudyUnsupported {
  var asked = 0;
  var wikiAnswers = true;
  var wikiFails = false;

  /// Names the server leaves out of its answers.
  final omitted = <String>{};
  @override
  Future<List<BooruTag>> tags(BooruServer server, List<String> names) async {
    asked += 1;
    return [
      for (final name in names)
        if (!omitted.contains(name)) BooruTag(name: name, count: 40, category: 0),
    ];
  }

  @override
  Future<StudyWiki?> wiki(BooruServer server, String tag) async {
    asked += 1;
    if (wikiFails) throw const NetworkErrorForTests();
    return wikiAnswers ? StudyWiki(title: tag, body: 'About $tag.', otherNames: const []) : null;
  }

  @override
  Future<List<StudyRelatedTag>> relatedTags(BooruServer server, String tag) async {
    asked += 1;
    return const [StudyRelatedTag(name: 'smile', category: 0, count: 5, frequency: 0.5)];
  }
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  late StudyCurriculum bundled;

  setUpAll(() {
    // What `loadBundled` reads from the asset bundle, read from the file for the other tests.
    bundled = StudyCurriculum.parse(File('assets/study/TagStudy.json').readAsStringSync());
    StudyCurriculum.useBundled(bundled);
  });
  tearDownAll(() => StudyCurriculum.useBundled(null));

  BooruStore storeWith({List<BooruServer> servers = const [], bool select = false}) {
    final store = BooruStore.inMemory();
    for (final server in servers) {
      store.saveServer(server);
    }
    if (select) store.setSelectedServers([for (final server in servers) server.id]);
    return store;
  }

  // MARK: Sync and backup

  test('study progress travels between devices and a day keeps its larger count', () {
    LibrarySyncAdapter adapter() {
      final preferences = AppPreferences.memory();
      return LibrarySyncAdapter(
        manga: AppDatabase.inMemory(preferences: preferences),
        booru: BooruStore.inMemory(preferences: preferences),
        mangaDefaults: preferences.defaults,
        booruDefaults: preferences.booruDefaults,
      );
    }

    final a = adapter(), b = adapter();
    final now = DateTime.fromMillisecondsSinceEpoch(1800000000 * 1000);
    a.booru.studyStore.answer('cowboy_shot', right: true, now: now);
    a.booru.studyStore.answer('cowboy_shot', right: true, now: now.add(const Duration(seconds: 60)));
    a.booru.studyStore.save(
      StudyTagInfo(name: 'cowboy_shot', count: 9, category: 0, related: const [], fetched: now, complete: true),
      address: 'example.org',
    );
    b.booru.studyStore.answer('smile', right: false, now: now);
    for (var i = 0; i < 4; i++) {
      b.booru.studyStore.answer('smile', right: true, now: now);
    }
    final rows = a.snapshot().values.where((row) => row.table.startsWith('booru.study_')).toList();
    expect({for (final row in rows) row.table}, {'booru.study_progress', 'booru.study_days'}, reason: 'What servers said about tags stays on the device');
    b.apply({for (final row in rows) row.key: LibrarySyncChange(row: row, timestamp: 100, device: 'A', deleted: false)});
    final progress = b.booru.studyStore.progress();
    expect(progress['cowboy_shot']?.step, 2);
    expect(progress['cowboy_shot']?.correct, 2);
    expect(progress['smile']?.correct, 4, reason: 'Tags the other device never studied are untouched');
    final day = b.booru.studyStore.days().first;
    expect(day.answered, 5, reason: 'The day studied more keeps its count');
    expect(day.correct, 4);
    expect(b.booru.studyStore.info('cowboy_shot', address: 'example.org'), isNull);

    // A row no version could have written is left out without failing the rest.
    final bad = LibrarySyncRow(
      table: 'booru.study_progress',
      values: {
        'tag': const SyncValue.text('smile'),
        'step': const SyncValue.integer(99),
        'due': const SyncValue.real(0),
        'correct': const SyncValue.integer(0),
        'wrong': const SyncValue.integer(0),
        'seen': const SyncValue.real(0),
      },
    );
    b.apply({bad.key: LibrarySyncChange(row: bad, timestamp: 200, device: 'A', deleted: false)});
    expect(b.booru.studyStore.progress()['smile']?.correct, 4);

    final gone = rows.firstWhere((row) => row.table == 'booru.study_progress');
    b.apply({gone.key: LibrarySyncChange(row: gone, timestamp: 300, device: 'A', deleted: true)});
    expect(b.booru.studyStore.progress()['cowboy_shot'], isNull, reason: 'A reset on one device reaches the others');
  });

  test('a backup carries study progress and merges without undoing later answers', () {
    final source = BooruStore.inMemory(), destination = BooruStore.inMemory();
    final early = DateTime.fromMillisecondsSinceEpoch(1800000000 * 1000), late = early.add(const Duration(days: 1));
    source.studyStore.answer('cowboy_shot', right: true, now: early);
    source.studyStore.answer('smile', right: true, now: late);
    destination.studyStore.answer('cowboy_shot', right: false, now: late);
    destination.studyStore.answer('smile', right: false, now: early);
    final backup = BooruBackup.decode(source.exportBackup().encoded());
    expect(backup.study?.progress.map((value) => value.tag), ['cowboy_shot', 'smile']);
    expect(backup.study?.progress.first.seen, 1800000000, reason: 'Times are written as seconds since 1970');
    destination.restoreBackup(backup);
    final progress = destination.studyStore.progress();
    expect(progress['cowboy_shot']?.wrong, 1, reason: 'The later answer on this device stays');
    expect(progress['cowboy_shot']?.correct, 0);
    expect(progress['smile']?.correct, 1, reason: "The backup's later answer replaces the earlier one here");
    expect(destination.studyStore.days().length, 2);

    final json = jsonDecode(utf8.decode(source.exportBackup().encoded())) as Map<String, Object?>;
    final written = (json['study']! as Map)['progress']! as List;
    expect((written.first as Map).keys.toSet(), {'tag', 'step', 'due', 'correct', 'wrong', 'seen'});
    expect(((json['study']! as Map)['days']! as List).first, {'day': StudyDay.key(early), 'answered': 1, 'correct': 1});
    json.remove('study');
    expect(BooruBackup.decode(utf8.encode(jsonEncode(json))).study, isNull, reason: 'Backups from before tag study still read');
    final invalid = BooruBackup.decode(source.exportBackup().encoded());
    final first = invalid.study!.progress.first;
    invalid.study!.progress[0] = BooruBackupLearned(tag: first.tag, step: 99, due: first.due, correct: first.correct, wrong: first.wrong, seen: first.seen);
    expect(invalid.validate, throwsA(isA<BooruError>()));
    final days = BooruBackup.decode(source.exportBackup().encoded());
    days.study!.days[0] = const StudyDay(day: '2027-01-15', answered: 1, correct: 2);
    expect(days.validate, throwsA(isA<BooruError>()), reason: 'A day cannot have more right answers than answers');
    expect(BooruStore.inMemory().exportBackup().study, isNull, reason: 'An unused feature adds nothing to the backup');
  });

  // MARK: Curriculum file

  test('the curriculum file is the same as the iOS one and loads from the asset bundle', () async {
    final native = File('../native-ios/TEGNAL/TagStudy.json');
    if (native.existsSync()) expect(File('assets/study/TagStudy.json').readAsBytesSync(), native.readAsBytesSync());
    StudyCurriculum.useBundled(null);
    expect(StudyCurriculum.bundled.units, isEmpty, reason: 'Empty until loaded');
    final loaded = await StudyCurriculum.loadBundled();
    expect(loaded.units.length, bundled.units.length);
    expect(loaded.count, bundled.count);
    expect(StudyCurriculum.bundled.count, bundled.count);
    expect(await StudyCurriculum.loadBundled(), same(loaded), reason: 'Read once');
    expect(StudyCurriculum.parse('not json').units, isEmpty);
    expect(StudyCurriculum.parse('{"version":1}').units, isEmpty);
  });

  test('the bundled curriculum has at least twelve units and four hundred tags', () {
    expect(bundled.units.length, greaterThanOrEqualTo(12));
    expect(bundled.tags.length, greaterThanOrEqualTo(400));
    expect(bundled.count, bundled.tags.length, reason: 'Every tag name appears once, so the index holds as many tags as the file');
  });

  test('bundled tag names are unique, lowercase and free of spaces and commas', () {
    final names = bundled.tags.map((tag) => tag.name).toList();
    expect(names.length, names.toSet().length);
    expect(names.where((name) => name != name.toLowerCase()), isEmpty);
    expect(names.where((name) => name.isEmpty || name.contains(' ') || name.contains(',')), isEmpty);
  });

  test('every bundled tag has Korean, Japanese and a note in all three languages', () {
    final problems = <String>[];
    for (final tag in bundled.tags) {
      if ((tag.ko ?? '').isEmpty) problems.add('${tag.name} ko');
      if ((tag.ja ?? '').isEmpty) problems.add('${tag.name} ja');
      for (final language in ['en', 'ko', 'ja']) {
        if ((tag.note[language] ?? '').isEmpty) problems.add('${tag.name} note.$language');
      }
    }
    expect(problems, isEmpty);
  });

  test('every bundled group and unit has titles in all three languages and ids are unique', () {
    final problems = <String>[], groupIDs = <String>[];
    for (final unit in bundled.units) {
      for (final language in ['en', 'ko', 'ja']) {
        if ((unit.title[language] ?? '').isEmpty) problems.add('${unit.id} title.$language');
        if ((unit.summary[language] ?? '').isEmpty) problems.add('${unit.id} summary.$language');
      }
      for (final group in unit.groups) {
        groupIDs.add(group.id);
        for (final language in ['en', 'ko', 'ja']) {
          if ((group.title[language] ?? '').isEmpty) problems.add('${group.id} title.$language');
        }
      }
    }
    expect(problems, isEmpty);
    expect(groupIDs.length, groupIDs.toSet().length);
    expect(bundled.units.map((unit) => unit.id).toSet().length, bundled.units.length, reason: 'Unit ids are unique');
  });

  test('every confusable names another tag in the curriculum', () {
    final problems = <String>[];
    for (final tag in bundled.tags) {
      for (final other in tag.confusable ?? const <String>[]) {
        if (other == tag.name) {
          problems.add('${tag.name} names itself');
        } else if (!bundled.contains(other)) {
          problems.add('${tag.name} -> $other is not taught');
        }
      }
    }
    expect(problems, isEmpty);
  });

  test('curriculum lookups agree on tag, group and unit for every bundled tag', () {
    final problems = <String>[];
    for (final unit in bundled.units) {
      expect(bundled.unit(unit.id)?.id, unit.id);
      for (final group in unit.groups) {
        for (final tag in group.tags) {
          if (!bundled.contains(tag.name)) problems.add('${tag.name} contains');
          if (bundled.tag(tag.name) != tag) problems.add('${tag.name} tag');
          if (bundled.groupOf(tag.name)?.id != group.id) problems.add('${tag.name} group');
          if (bundled.unitOf(tag.name)?.id != unit.id) problems.add('${tag.name} unit');
        }
      }
    }
    expect(problems, isEmpty);
    expect(bundled.contains('definitely_not_a_study_tag'), isFalse);
    expect(bundled.tag('definitely_not_a_study_tag'), isNull);
    expect(bundled.groupOf('definitely_not_a_study_tag'), isNull);
    expect(bundled.unitOf('definitely_not_a_study_tag'), isNull);
  });

  test('every unit has a symbol and the names are the ones iOS uses', () {
    expect(bundled.units.map((unit) => unit.symbol).toSet().contains('tag'), isFalse, reason: 'Every bundled unit has its own symbol');
    expect(bundled.unit('count')?.symbol, 'person.2');
    expect(bundled.unit('hair')?.symbol, 'comb');
    expect(StudyUnit(id: 'other', title: const {}, summary: const {}, groups: const []).symbol, 'tag');
  });

  test('titles follow the language and fall back to the tag read as words', () {
    final tag = StudyTag(name: 'long_hair', ko: '긴 머리', note: const {'en': 'a', 'ja': 'b'});
    expect(tag.title('ko'), '긴 머리');
    expect(tag.title('ja'), 'long hair', reason: 'A missing translation reads the tag');
    expect(tag.title('en'), 'long hair');
    expect(const {'en': 'x', 'ko': 'y'}.resolved('ko'), 'y');
    expect(const {'en': 'x'}.resolved('ja'), 'x');
    expect(const <String, String>{}.resolved('ja'), '');
  });

  test('taught lists a posts curriculum tags in curriculum order and skips others', () {
    final all = bundled.tags;
    final first = all.first, middle = all[all.length ~/ 2], last = all.last;
    final tagged = post(1, [last.name, 'definitely_not_a_study_tag', first.name, middle.name]);
    expect(bundled.taughtIn(tagged).map((tag) => tag.name), [first.name, middle.name, last.name]);
    expect(bundled.taughtIn(post(2, ['definitely_not_a_study_tag'])), isEmpty);
  });

  // MARK: StudyProgress

  test('right answers move one step up and schedule the next asking by the step interval', () {
    final now = DateTime.fromMillisecondsSinceEpoch(1800000000 * 1000, isUtc: true);
    var progress = StudyProgress(tag: 'solo');
    for (var step = 1; step <= StudyProgress.lastStep; step++) {
      progress = progress.answered(true, now: now);
      expect(progress.step, step);
      expect(progress.due, now.add(Duration(seconds: (StudyProgress.intervals[step] * 86400).round())));
      expect(progress.seen, now);
      expect(progress.correct, step);
    }
    final beyond = progress.answered(true, now: now);
    expect(beyond.step, StudyProgress.lastStep, reason: 'The step stops at the last one');
    expect(beyond.due, now.add(Duration(seconds: (StudyProgress.intervals[StudyProgress.lastStep] * 86400).round())));
    expect(beyond.correct, StudyProgress.lastStep + 1);
  });

  test('a wrong answer returns to step zero and asks again in ten minutes', () {
    final now = DateTime.fromMillisecondsSinceEpoch(1800000000 * 1000, isUtc: true);
    var progress = StudyProgress(tag: 'solo', step: 5, due: now.add(const Duration(days: 1)), correct: 5);
    progress = progress.answered(false, now: now);
    expect(progress.step, 0);
    expect(progress.due, now.add(const Duration(seconds: 600)));
    expect(progress.wrong, 1);
    expect(progress.correct, 5);
    expect(progress.seen, now);
  });

  test('learned, new and due follow the step, the counts and the due date', () {
    final now = DateTime.fromMillisecondsSinceEpoch(1800000000 * 1000);
    expect(StudyProgress(tag: 'a', step: StudyProgress.learnedStep - 1).isLearned, isFalse);
    expect(StudyProgress(tag: 'a', step: StudyProgress.learnedStep).isLearned, isTrue);
    expect(StudyProgress(tag: 'a', step: StudyProgress.lastStep).isLearned, isTrue);
    final fresh = StudyProgress(tag: 'a');
    expect(fresh.isNew, isTrue);
    expect(fresh.isDue(now), isFalse, reason: 'A tag never asked is new, not due, even though its due date is long past');
    expect(fresh.answered(true, now: now).isNew, isFalse);
    expect(StudyProgress(tag: 'a', wrong: 1).isNew, isFalse);
    expect(StudyProgress(tag: 'a', due: now.subtract(const Duration(seconds: 1)), correct: 1).isDue(now), isTrue);
    expect(StudyProgress(tag: 'a', due: now, correct: 1).isDue(now), isTrue);
    expect(StudyProgress(tag: 'a', due: now.add(const Duration(seconds: 1)), correct: 1).isDue(now), isFalse);
  });

  // MARK: StudyStore

  test('the study tables come from the booru_v14_study migration', () {
    final store = BooruStore.inMemory();
    expect(store.database.column<String>('SELECT identifier FROM grdb_migrations').last, 'booru_v14_study');
    expect(store.database.columns('study_progress'), ['tag', 'step', 'due', 'correct', 'wrong', 'seen']);
    expect(store.database.columns('study_days'), ['day', 'answered', 'correct']);
    expect(store.database.columns('study_tags'), ['address', 'name', 'payload', 'fetched']);
  });

  test('answer writes progress and adds to the days row, and both read back', () {
    final study = BooruStore.inMemory().studyStore;
    final now = DateTime.fromMillisecondsSinceEpoch(1800000000 * 1000, isUtc: true);
    final first = study.answer('solo', right: true, now: now, utcOffset: utc);
    expect(first.step, 1);
    study.answer('solo', right: false, now: now.add(const Duration(seconds: 60)), utcOffset: utc);
    study.answer('1girl', right: true, now: now.add(const Duration(seconds: 120)), utcOffset: utc);
    final progress = study.progress();
    expect(progress.keys.toSet(), {'solo', '1girl'});
    expect(progress['solo']?.step, 0);
    expect(progress['solo']?.correct, 1);
    expect(progress['solo']?.wrong, 1);
    expect(progress['solo']?.due, now.add(const Duration(seconds: 660)));
    expect(progress['1girl']?.step, 1);
    expect(progress['1girl']?.due, now.add(const Duration(seconds: 120 + 86400)));
    expect(study.days(), [StudyDay(day: StudyDay.key(now, utcOffset: utc), answered: 3, correct: 2)]);
  });

  test('times are stored as seconds since 1970 and days as local yyyy-MM-dd text', () {
    final store = BooruStore.inMemory();
    final now = DateTime.fromMillisecondsSinceEpoch(1800000000 * 1000, isUtc: true);
    store.studyStore.answer('solo', right: true, now: now, utcOffset: utc);
    final row = store.database.row('SELECT * FROM study_progress')!;
    expect(row['seen'], 1800000000.0);
    expect(row['due'], 1800000000.0 + 86400);
    expect(store.database.value<String>('SELECT typeof(due) FROM study_progress'), 'real');
    expect(store.database.value<String>('SELECT day FROM study_days'), '2027-01-15');
    expect(StudyProgress(tag: 'x').due, StudyProgress.distantPast);
    expect(StudyDay.key(date(2026, 3, 8), utcOffset: utc), '2026-03-08');
  });

  test('days are read newest first and answers on a different day are separate rows', () {
    final study = BooruStore.inMemory().studyStore;
    study.answer('solo', right: true, now: date(2026, 3, 8), utcOffset: utc);
    study.answer('solo', right: false, now: date(2026, 3, 9), utcOffset: utc);
    expect(study.days().map((day) => day.day), ['2026-03-09', '2026-03-08']);
    expect(study.days().map((day) => day.correct), [0, 1]);
  });

  test('reset clears progress and days but keeps the cached tag info', () {
    final study = BooruStore.inMemory().studyStore;
    study.answer('solo', right: true, now: date(2026, 3, 8), utcOffset: utc);
    study.save(tagInfo('solo', count: 12), address: 'https://a.example');
    study.reset();
    expect(study.progress(), isEmpty);
    expect(study.days(), isEmpty);
    expect(study.info('solo', address: 'https://a.example')?.count, 12);
  });

  test('the tag info cache is keyed by address and counts list only that addresses known counts', () {
    final study = BooruStore.inMemory().studyStore;
    final info = tagInfo('solo', count: 12);
    study.save(info, address: 'https://a.example');
    study.save(tagInfo('1girl', count: 7), address: 'https://a.example');
    study.save(tagInfo('hug'), address: 'https://a.example');
    study.save(tagInfo('solo', count: 99), address: 'https://b.example');
    expect(study.info('solo', address: 'https://a.example'), info);
    expect(study.info('solo', address: 'https://b.example')?.count, 99);
    expect(study.info('1girl', address: 'https://b.example'), isNull);
    expect(study.info('unknown', address: 'https://a.example'), isNull);
    expect(study.counts(address: 'https://a.example'), {'solo': 12, '1girl': 7});
    expect(study.counts(address: 'https://b.example'), {'solo': 99});
    expect(study.counts(address: 'https://c.example'), isEmpty);
    // Saving again for the same name replaces the earlier answer.
    study.save(tagInfo('solo', count: 13), address: 'https://a.example');
    expect(study.info('solo', address: 'https://a.example')?.count, 13);
  });

  test('cached tag info is written the way iOS writes it, and unreadable rows are ignored', () {
    final store = BooruStore.inMemory();
    final study = store.studyStore;
    study.save(
      StudyTagInfo(name: 'solo', count: 3, related: const [], fetched: DateTime.utc(2027, 1, 15), complete: false),
      address: 'a',
    );
    final payload = jsonDecode(utf8.decode(store.database.value<Uint8List>('SELECT payload FROM study_tags')!)) as Map<String, Object?>;
    expect(payload, {
      'name': 'solo',
      'count': 3,
      'related': [],
      'fetched': DateTime.utc(2027, 1, 15).millisecondsSinceEpoch / 1000 - 978307200,
      'complete': false,
    });
    store.database.execute('INSERT INTO study_tags VALUES (?, ?, ?, ?)', ['a', 'broken', Uint8List.fromList(utf8.encode('{')), 1.0e12]);
    expect(study.info('broken', address: 'a'), isNull);
    expect(study.counts(address: 'a'), {'solo': 3});
  });

  test('saving drops answers older than four lifetimes', () {
    final store = BooruStore.inMemory();
    final study = store.studyStore;
    final old = DateTime.now().subtract(StudyTagInfo.lifetime * 5);
    study.save(
      StudyTagInfo(name: 'ancient', count: 1, related: const [], fetched: old, complete: true),
      address: 'a',
    );
    expect(study.info('ancient', address: 'a'), isNull, reason: 'It left as soon as it was saved');
    study.save(
      StudyTagInfo(name: 'recent', count: 1, related: const [], fetched: DateTime.now().subtract(StudyTagInfo.lifetime * 2), complete: true),
      address: 'a',
    );
    expect(study.info('recent', address: 'a'), isNotNull);
  });

  test('tag info goes stale after fourteen days', () {
    final fetched = DateTime.utc(2026, 3, 1);
    final info = StudyTagInfo(name: 'solo', related: const [], fetched: fetched, complete: true);
    expect(info.isStale(fetched.add(const Duration(days: 14))), isFalse);
    expect(info.isStale(fetched.add(const Duration(days: 14, seconds: 1))), isTrue);
  });

  test('deleting a server removes that addresses cached tag info and leaves another address alone', () {
    final first = BooruServer(id: 'study-first', name: 'First', baseURL: 'https://first.example', engine: BooruEngine.danbooru);
    final second = BooruServer(id: 'study-second', name: 'Second', baseURL: 'https://second.example', engine: BooruEngine.danbooru);
    final store = storeWith(servers: [first, second]);
    final study = store.studyStore;
    study.save(tagInfo('solo', count: 1), address: first.canonicalAddress);
    study.save(tagInfo('solo', count: 2), address: second.canonicalAddress);
    study.answer('solo', right: true, now: date(2026, 3, 8), utcOffset: utc);
    store.deleteServer(first);
    expect(study.info('solo', address: first.canonicalAddress), isNull);
    expect(study.info('solo', address: second.canonicalAddress)?.count, 2);
    expect(study.progress().length, 1, reason: 'What was learned belongs to the tag, not to a server');
  });

  // MARK: StudySummary

  test('summary counts total, started, learned and due only for curriculum tags', () {
    final now = date(2026, 3, 10);
    final progress = {
      't1': StudyProgress(tag: 't1', step: 4, due: now.add(const Duration(days: 1)), correct: 4), // learned, not due
      't2': StudyProgress(tag: 't2', step: 1, due: now.subtract(const Duration(seconds: 60)), correct: 1), // started and due
      't3': StudyProgress(tag: 't3', step: 0, due: now.add(const Duration(seconds: 600)), wrong: 1), // started
      't4': StudyProgress(tag: 't4'), // new
      'w1': StudyProgress(tag: 'w1', step: 6, due: now.subtract(const Duration(seconds: 10)), correct: 7), // learned and due
      'outside': StudyProgress(tag: 'outside', step: 6, due: now.subtract(const Duration(seconds: 10)), correct: 7),
    };
    final summary = StudySummary.of(curriculum: roundCurriculum(), progress: progress, days: const [], now: now, utcOffset: utc);
    expect(summary.total, 11);
    expect(summary.started, 4);
    expect(summary.learned, 2);
    expect(summary.due, 2);
    expect(summary.streak, 0);
    expect(const StudySummary(), const StudySummary(total: 0));
    expect(StudySummary.unit(roundCurriculum().units.first, progress: progress), (learned: 1, started: 3, total: 8));
  });

  test('summary reports todays answers and right answers', () {
    final now = date(2026, 3, 10);
    final days = [const StudyDay(day: '2026-03-10', answered: 5, correct: 3), const StudyDay(day: '2026-03-09', answered: 9, correct: 9)];
    final summary = StudySummary.of(curriculum: roundCurriculum(), progress: const {}, days: days, now: now, utcOffset: utc);
    expect(summary.today, 5);
    expect(summary.todayCorrect, 3);
    final quiet = StudySummary.of(curriculum: roundCurriculum(), progress: const {}, days: [days[1]], now: now, utcOffset: utc);
    expect(quiet.today, 0);
    expect(quiet.todayCorrect, 0);
  });

  int streak(List<StudyDay> days, DateTime now, {Duration offset = utc}) =>
      StudySummary.of(curriculum: roundCurriculum(), progress: const {}, days: days, now: now, utcOffset: offset).streak;

  test('a streak counts consecutive days ending today', () {
    final days = [
      const StudyDay(day: '2026-03-10', answered: 1, correct: 1),
      const StudyDay(day: '2026-03-09', answered: 4, correct: 2),
      const StudyDay(day: '2026-03-08', answered: 2, correct: 0),
      const StudyDay(day: '2026-03-06', answered: 8, correct: 8),
    ];
    expect(streak(days, date(2026, 3, 10)), 3);
  });

  test('a streak still counts when today has no answers yet but yesterday does', () {
    final days = [const StudyDay(day: '2026-03-09', answered: 4, correct: 2), const StudyDay(day: '2026-03-08', answered: 2, correct: 0)];
    expect(streak(days, date(2026, 3, 10)), 2);
    // A row with nothing answered is not a day of study.
    expect(streak([const StudyDay(day: '2026-03-10'), ...days], date(2026, 3, 10)), 2);
  });

  test('a streak is zero after a gap of more than one day', () {
    final days = [const StudyDay(day: '2026-03-08', answered: 4, correct: 2), const StudyDay(day: '2026-03-07', answered: 2, correct: 0)];
    expect(streak(days, date(2026, 3, 10)), 0);
    expect(streak(const [], date(2026, 3, 10)), 0);
  });

  test('a streak follows the time zone, not UTC', () {
    // 2026-03-10 20:00 UTC is already 2026-03-11 in Tokyo.
    final days = [const StudyDay(day: '2026-03-11', answered: 1, correct: 1), const StudyDay(day: '2026-03-10', answered: 1, correct: 1)];
    final summary = StudySummary.of(
      curriculum: roundCurriculum(),
      progress: const {},
      days: days,
      now: date(2026, 3, 10, hour: 20),
      utcOffset: const Duration(hours: 9),
    );
    expect(summary.today, 1);
    expect(summary.streak, 2);
    expect(streak(days, date(2026, 3, 10, hour: 20)), 1, reason: 'In UTC it is still the tenth');
  });

  test('a streak in the device time zone crosses a month end', () {
    final now = DateTime(2026, 3, 1, 12);
    final days = [
      for (final day in ['2026-03-01', '2026-02-28', '2026-02-27']) StudyDay(day: day, answered: 1, correct: 1),
    ];
    expect(StudySummary.of(curriculum: roundCurriculum(), progress: const {}, days: days, now: now).streak, 3);
  });

  // MARK: StudyEngine.round

  test('review returns only due tags, longest overdue first', () {
    final now = date(2026, 3, 10);
    final progress = {
      't1': due('t1', now, daysAgo: 1),
      't3': due('t3', now, daysAgo: 3),
      't5': due('t5', now, daysAgo: 5),
      't2': StudyProgress(tag: 't2', step: 2, due: now.add(const Duration(days: 1)), correct: 2),
      'w1': due('w1', now, daysAgo: 2),
    };
    expect(roundEngine().round(StudyScope.review, progress: progress, now: now, random: Random(1)).map((tag) => tag.name), ['t5', 't3', 'w1', 't1']);
    expect(roundEngine().round(StudyScope.review, progress: progress, count: 2, now: now, random: Random(1)).map((tag) => tag.name), ['t5', 't3']);
    expect(
      roundEngine().round(StudyScope.review, progress: const {}, now: now, random: Random(1)),
      isEmpty,
      reason: 'Nothing is due before anything is asked',
    );
  });

  test('today puts due tags first and leaves room for three new tags in curriculum order', () {
    final now = date(2026, 3, 10);
    // Four tags are due, longest overdue first: t4, t2, t3, t1. The rest are new.
    final progress = {'t1': due('t1', now, daysAgo: 1), 't2': due('t2', now, daysAgo: 8), 't3': due('t3', now, daysAgo: 2), 't4': due('t4', now, daysAgo: 9)};
    expect(roundEngine().round(StudyScope.today, progress: progress, count: 5, now: now, random: Random(7)).map((tag) => tag.name), [
      't4',
      't2',
      't5',
      't6',
      't7',
    ]);
    expect(roundEngine().round(StudyScope.today, progress: progress, now: now, random: Random(7)).map((tag) => tag.name), [
      't4',
      't2',
      't3',
      't1',
      't5',
      't6',
      't7',
      't8',
      'w1',
      'w2',
    ]);
  });

  test('today never returns more than the count and has no duplicates', () {
    final now = date(2026, 3, 10);
    final progress = {for (var index = 1; index <= 8; index++) 't$index': due('t$index', now, daysAgo: index)};
    for (final count in [1, 2, 3, 4, 8, 20]) {
      final round = roundEngine().round(StudyScope.today, progress: progress, count: count, now: now, random: Random(count)).map((tag) => tag.name).toList();
      expect(round.length, lessThanOrEqualTo(count));
      expect(round.length, round.toSet().length);
    }
    expect(roundEngine().round(StudyScope.today, progress: progress, count: 4, now: now, random: Random(3)).map((tag) => tag.name), [
      't8',
      'w1',
      'w2',
      'w3',
    ], reason: 'One due tag keeps three places for new ones');
  });

  test('today with nothing due or new is empty', () {
    final now = date(2026, 3, 10);
    final progress = {
      for (final tag in roundCurriculum().tags) tag.name: StudyProgress(tag: tag.name, step: 2, due: now.add(const Duration(days: 1)), correct: 2),
    };
    expect(roundEngine().round(StudyScope.today, progress: progress, now: now, random: Random(3)), isEmpty);
  });

  test('a unit round holds only that units tags and fills up with seen tags, least known first', () {
    final now = date(2026, 3, 10);
    final future = now.add(const Duration(days: 1));
    // t3 to t8 are new and come first in curriculum order; the seen ones follow, least known first.
    final progress = {
      't1': StudyProgress(tag: 't1', step: 3, due: future, correct: 3),
      't2': StudyProgress(tag: 't2', step: 1, due: future, correct: 1),
      'w1': StudyProgress(tag: 'w1', step: 0, due: future, correct: 1),
    };
    for (var seed = 0; seed < 20; seed++) {
      final round = roundEngine().round(const StudyScope.unit('r1'), progress: progress, count: 8, now: now, random: Random(seed)).map((tag) => tag.name);
      expect(round, ['t3', 't4', 't5', 't6', 't7', 't8', 't2', 't1'], reason: 'seed $seed');
    }
    final wide = roundEngine().round(const StudyScope.unit('r1'), progress: progress, count: 20, now: now, random: Random(1)).map((tag) => tag.name);
    expect(wide, ['t3', 't4', 't5', 't6', 't7', 't8', 't2', 't1'], reason: "The other unit's tags never join");
    expect(roundEngine().round(const StudyScope.unit('nothing'), progress: progress, now: now, random: Random(1)), isEmpty);
  });

  test('a unit round with everything seen asks the least known tags first', () {
    final now = date(2026, 3, 10);
    final future = now.add(const Duration(days: 1));
    final progress = {
      for (final entry in {'w1': 4, 'w2': 1, 'w3': 3}.entries) entry.key: StudyProgress(tag: entry.key, step: entry.value, due: future, correct: 1),
    };
    for (var seed = 0; seed < 20; seed++) {
      expect(roundEngine().round(const StudyScope.unit('r2'), progress: progress, count: 3, now: now, random: Random(seed)).map((tag) => tag.name), [
        'w2',
        'w3',
        'w1',
      ], reason: 'seed $seed');
      expect(roundEngine().round(const StudyScope.unit('r2'), progress: progress, count: 2, now: now, random: Random(seed)).map((tag) => tag.name), [
        'w2',
        'w3',
      ], reason: 'seed $seed');
    }
  });

  test('the tags scope keeps only curriculum tags without duplicates in the given order', () {
    final round = roundEngine().round(
      const StudyScope.tags(['w2', 'not_taught', 't1', 'w2', 't1', 't5']),
      progress: const {},
      now: date(2026, 3, 10),
      random: Random(5),
    );
    expect(round.map((tag) => tag.name), ['w2', 't1', 't5']);
  });

  test('scopes are equal by value', () {
    expect(const StudyScope.unit('a'), const StudyScope.unit('a'));
    expect(const StudyScope.unit('a'), isNot(const StudyScope.unit('b')));
    expect(const StudyScope.tags(['a', 'b']), const StudyScope.tags(['a', 'b']));
    expect(StudyScope.today, isNot(StudyScope.review));
  });

  // MARK: StudyEngine.usable / teaches / distractors

  test('videos, animated, removed and pictureless posts are not usable', () {
    expect(StudyEngine.usable(post(1, ['solo'])), isTrue);
    expect(StudyEngine.usable(post(2, ['solo'], ext: 'mp4')), isFalse);
    expect(StudyEngine.usable(post(3, ['solo'], ext: 'gif')), isFalse);
    expect(StudyEngine.usable(post(4, ['solo', 'animated'])), isFalse);
    expect(StudyEngine.usable(post(5, ['solo'])..isDeleted = true), isFalse);
    expect(StudyEngine.usable(post(6, ['solo'])..isBanned = true), isFalse);
    expect(
      StudyEngine.usable(
        post(7, ['solo'])
          ..previewURL = null
          ..sampleURL = null
          ..fileURL = null,
      ),
      isFalse,
    );
    expect(StudyEngine.usable(post(8, ['solo'])..previewURL = null), isTrue);
  });

  test('an exclusive group teaches neither tag when a post carries two of its tags, but a non-exclusive group teaches both', () {
    final engine = tinyEngine();
    final s1 = tinyTag('s1'), s2 = tinyTag('s2'), m1 = tinyTag('m1'), m2 = tinyTag('m2');
    final shots = post(1, ['s1', 's2', 'm1']);
    expect(engine.teaches(shots, s1), isFalse);
    expect(engine.teaches(shots, s2), isFalse);
    expect(engine.teaches(post(2, ['s1', 'm1']), s1), isTrue, reason: 'Tags of other groups do not matter');
    final misc = post(3, ['m1', 'm2']);
    expect(engine.teaches(misc, m1), isTrue);
    expect(engine.teaches(misc, m2), isTrue);
    expect(engine.teaches(post(4, ['m2']), m1), isFalse, reason: 'A picture without the tag teaches nothing');
    expect(
      engine.teaches(post(5, ['stray']), const StudyTag(name: 'stray', note: {})),
      isTrue,
      reason: 'A tag without a group is taught by any picture that carries it',
    );
  });

  test('distractors never include the tag or excluded names, have no duplicates and take confusable tags first', () {
    final engine = tinyEngine();
    final s1 = engine.curriculum.tag('s1')!;
    expect(s1.confusable, ['m1']);
    for (var seed = 0; seed < 30; seed++) {
      final wrong = engine.distractors(s1, excluding: {'s2'}, random: Random(seed)).map((tag) => tag.name).toList();
      expect(wrong.length, 3, reason: 'seed $seed');
      expect(wrong.length, wrong.toSet().length);
      expect(wrong, isNot(contains('s1')));
      expect(wrong, isNot(contains('s2')));
      expect(wrong.first, 'm1', reason: 'The confusable tag comes before tags of the same group');
      expect(wrong.skip(1).toSet().difference({'s3', 's4'}), isEmpty, reason: 'Then tags answering the same question: $wrong');
    }
  });

  test('distractors fill up from the unit and then the whole curriculum and stop when it runs out', () {
    final engine = tinyEngine();
    final s1 = engine.curriculum.tag('s1')!;
    final many = engine.distractors(s1, count: 9, random: Random(11)).map((tag) => tag.name).toList();
    expect(many.length, 9);
    expect(many.length, many.toSet().length);
    expect(many, isNot(contains('s1')));
    final all = engine.distractors(s1, count: 100, random: Random(11)).map((tag) => tag.name).toSet();
    expect(all, engine.curriculum.tags.map((tag) => tag.name).toSet()..remove('s1'), reason: 'Nothing else is left to offer');
    expect(engine.distractors(s1, excluding: engine.curriculum.tags.map((tag) => tag.name).toSet(), random: Random(11)), isEmpty);
  });

  // MARK: StudyEngine.question

  test('an empty pool or a non-visual group asks by meaning', () {
    final engine = tinyEngine();
    for (var seed = 0; seed < 25; seed++) {
      final random = Random(seed);
      final empty = engine.question(tinyTag('s1'), pool: const [], random: random);
      expect(empty?.kind, StudyQuestionKind.meaningToTag, reason: 'seed $seed');
      expect(empty?.choices[empty.answer].name, 's1');
      expect(empty?.posts, isEmpty);
      // Even with pictures that carry the tag, a tag that cannot be told by looking is asked by meaning.
      final pool = [
        post(1, ['x1']),
        post(2, ['x1', 'm1']),
        post(3, ['s2']),
        post(4, ['s3']),
        post(5, ['s4']),
      ];
      final abstract = engine.question(tinyTag('x1'), pool: pool, random: random);
      expect(abstract?.kind, StudyQuestionKind.meaningToTag, reason: 'seed $seed');
      expect(abstract?.choices[abstract.answer].name, 'x1');
      expect(abstract?.posts, isEmpty);
    }
  });

  test('a picture question shows an example and offers the tag among choices not on the post', () {
    final engine = tinyEngine();
    final shown = post(1, ['s1', 'm1', 'scenery']);
    for (var seed = 0; seed < 40; seed++) {
      final question = engine.question(
        tinyTag('s1'),
        pool: [shown],
        kinds: {StudyQuestionKind.pictureToTag, StudyQuestionKind.meaningToTag},
        random: Random(seed),
      )!;
      expect(question.kind, StudyQuestionKind.pictureToTag, reason: 'seed $seed');
      expect(question.posts.single, same(shown));
      expect(question.choices[question.answer].name, 's1');
      expect(question.choices.length, greaterThanOrEqualTo(3));
      expect(question.choices.length, question.choices.map((choice) => choice.name).toSet().length);
      expect(question.choiceCount, question.choices.length);
      for (final (index, choice) in question.choices.indexed) {
        if (index != question.answer) expect(shown.tags, isNot(contains(choice.name)), reason: '${choice.name} is on the shown picture');
      }
    }
  });

  test('a picture with two tags of an exclusive group is not used as an example', () {
    final question = tinyEngine().question(
      tinyTag('s1'),
      pool: [
        post(1, ['s1', 's2']),
      ],
      kinds: {StudyQuestionKind.pictureToTag, StudyQuestionKind.meaningToTag},
      random: Random(2),
    )!;
    expect(question.kind, StudyQuestionKind.meaningToTag);
  });

  test('a picture-choice question offers the tags picture among three that carry neighbouring tags only', () {
    final engine = tinyEngine();
    final pool = [
      post(1, ['s1', 'm1']),
      post(2, ['s2']),
      post(3, ['s3', 'm2']),
      post(4, ['s4']),
      post(5, ['m3']),
    ];
    const siblings = {'s2', 's3', 's4'};
    var found = false;
    for (var seed = 0; seed < 200 && !found; seed++) {
      final question = engine.question(
        tinyTag('s1'),
        pool: pool,
        kinds: {StudyQuestionKind.tagToPicture, StudyQuestionKind.meaningToTag},
        random: Random(seed),
      )!;
      if (question.kind != StudyQuestionKind.tagToPicture) {
        expect(question.kind, StudyQuestionKind.meaningToTag);
        continue;
      }
      found = true;
      expect(question.posts.length, 4);
      expect(question.choiceCount, 4);
      expect(question.posts.map((value) => value.id).toSet().length, 4);
      expect(question.posts[question.answer].tags, contains('s1'));
      for (final (index, shown) in question.posts.indexed) {
        if (index == question.answer) continue;
        expect(shown.tags, isNot(contains('s1')));
        expect(siblings.intersection(shown.tags.toSet()), isNotEmpty, reason: 'Each wrong picture carries another tag of the group');
      }
      expect(question.choices, isEmpty);
    }
    expect(found, isTrue, reason: 'No seed of 200 produced a picture-choice question');
  });

  test('a picture-choice question is not asked without three wrong pictures with neighbouring tags', () {
    final pool = [
      post(1, ['s1']),
      post(2, ['s2']),
      post(3, ['m1']),
      post(4, ['scenery']),
    ];
    for (var seed = 0; seed < 60; seed++) {
      final question = tinyEngine().question(
        tinyTag('s1'),
        pool: pool,
        kinds: {StudyQuestionKind.tagToPicture, StudyQuestionKind.meaningToTag},
        random: Random(seed),
      )!;
      expect(question.kind, StudyQuestionKind.meaningToTag, reason: 'seed $seed');
    }
  });

  test('no question is made when the allowed kinds cannot be asked', () {
    expect(
      tinyEngine().question(tinyTag('s1'), pool: const [], kinds: {StudyQuestionKind.pictureToTag, StudyQuestionKind.tagToPicture}, random: Random(4)),
      isNull,
    );
  });

  // MARK: StudyPrompt

  test('words turn underscores into spaces but keep emoticons and punctuation tags', () {
    expect(StudyPrompt.words('long_hair'), 'long hair');
    expect(StudyPrompt.words('looking_at_viewer'), 'looking at viewer');
    expect(StudyPrompt.words('1girl'), '1girl');
    for (final keep in ['^_^', '>_<', ':d', '!']) {
      expect(StudyPrompt.words(keep), keep);
    }
    expect(plainTag('long_hair').english, 'long hair');
  });

  test('ordered gives headcount, then characters, then series, then general tags, and leaves out bookkeeping', () {
    final tagged =
        post(1, ['smile', 'artist_x', 'vocaloid', 'hatsune_miku', 'solo', '1girl', 'absurdres', 'translated', 'meta_x', 'cat5', 'scenery', 'smile', 'highres'])
          ..artists = ['artist_x']
          ..metadataTags = ['meta_x']
          ..tagCategories = {'hatsune_miku': 4, 'vocaloid': 3, 'cat5': 5, 'artist_x': 1};
    expect(StudyPrompt.ordered(tagged), ['solo', '1girl', 'hatsune_miku', 'vocaloid', 'smile', 'scenery']);
    expect(StudyPrompt.ordered(tagged, artists: true), ['solo', '1girl', 'hatsune_miku', 'vocaloid', 'artist_x', 'smile', 'scenery']);
  });

  test('prompt text writes natural, escaped and raw tag styles', () {
    const tags = ['long_hair', '^_^', 'bow_(weapon)', 'blue_eyes'];
    expect(StudyPrompt.text(tags, style: StudyPromptStyle.natural), 'long hair, ^_^, bow (weapon), blue eyes');
    expect(StudyPrompt.text(tags, style: StudyPromptStyle.escaped), r'long hair, ^_^, bow \(weapon\), blue eyes');
    expect(StudyPrompt.text(tags, style: StudyPromptStyle.tags), 'long_hair ^_^ bow_(weapon) blue_eyes');
    expect(StudyPrompt.text(const [], style: StudyPromptStyle.natural), '');
  });

  // MARK: StudyDText

  test('blocks read headings, bullets and wrapped paragraphs and drop embedded posts, tables and expand marks', () {
    const text = '''
h4. Title
Some wrapped
text here.
h4#anchor. Second
* one
** two
!post #1
* !post #1
[table]
[tr][td]x[/td][/tr]
[/table]
[expand=More]
Hidden words
[/expand]''';
    expect(describe(StudyDText.blocks(text)), ['h:Title', 'p:Some wrapped text here.', 'h:Second', 'b1:one', 'b2:two', 'p:Hidden words']);
  });

  test('blocks separate paragraphs at blank lines and tolerate Windows line endings', () {
    expect(describe(StudyDText.blocks('first line\r\nsecond line\r\n\r\nnext')), ['p:first line second line', 'p:next']);
    expect(describe(StudyDText.blocks('[table]a[/table]\nafter')), ['p:after']);
    expect(describe(StudyDText.blocks('')), isEmpty);
    expect(StudyDText.blocks(List.filled(300, 'line\n').join('\n')).length, 120, reason: 'A page is cut off at the block limit');
  });

  test('inline turns tag links into links the reader can open', () {
    final plain = StudyDText.inline('see [[cowboy shot]] now');
    expect(plainText(plain), 'see cowboy shot now');
    expect(links(plain).map((link) => link.text), ['cowboy shot']);
    expect(links(plain).map((link) => link.tag), ['cowboy_shot']);

    final labelled = StudyDText.inline('[[cowboy_shot|a framing]] and [[watercolor (medium)|]]');
    expect(plainText(labelled), 'a framing and watercolor');
    expect(links(labelled).map((link) => link.text), ['a framing', 'watercolor']);
    expect(links(labelled).map((link) => link.tag), ['cowboy_shot', 'watercolor_(medium)']);
    expect(links(StudyDText.inline('[[hair#section]]')).map((link) => link.tag), ['hair']);
  });

  test('inline marks bold and italic and shows only the label of an ordinary link', () {
    final bold = StudyDText.inline('a [b]bold[/b] word');
    expect(plainText(bold), 'a bold word');
    expect(bold.where((span) => span.bold).map((span) => span.text), ['bold']);
    expect(bold.where((span) => !span.bold).map((span) => span.text), ['a ', ' word']);
    final both = StudyDText.inline('[i][b]both[/b] italic[/i]');
    expect(both.map((span) => (span.text, span.bold, span.italic)), [('both', true, true), (' italic', false, true)]);

    final external = StudyDText.inline('see "label":https://example.org now');
    expect(plainText(external), 'see label now');
    expect(links(external), isEmpty, reason: 'An outside address is not opened from the reader');
    expect(plainText(StudyDText.inline('{{search tag}} and <https://example.org> [color=red]x[/color]')), 'search tag and https://example.org x');
  });

  test('plain joins headings, bullets and paragraphs into copyable lines', () {
    expect(StudyDText.plain('h4. Head\n* item\ntext [[a b]]'), 'Head\n• item\ntext a b');
    expect(StudyDText.tagName(' Cowboy Shot '), 'cowboy_shot');
  });

  // MARK: BooruClient

  test('Danbooru tags requests the sorted comma-joined names with an only field list', () async {
    final (client, fetcher) = mocked(tagsReply);
    final found = await client.tags(dan, ['b', 'a', 'a', 'with space', 'with,comma']);
    expect(fetcher.requests.length, 1);
    final request = fetcher.requests.first;
    expect(request.url.path.endsWith('/tags.json'), isTrue);
    expect(query(request)['search[name_comma]'], 'a,b');
    expect(query(request)['only'], 'name,post_count,category');
    expect(query(request)['limit'], '2');
    expect(found.map((tag) => tag.name).toList()..sort(), ['a', 'b']);
    expect(found.firstWhere((tag) => tag.name == 'b').count, 2);
  });

  test('tags are asked in several requests when there are more than one batch', () async {
    final (client, fetcher) = mocked(tagsReply);
    final names = [for (var index = 0; index < BooruClient.tagBatch * 2 + 5; index++) 'tag${index.toString().padLeft(4, '0')}'];
    final found = await client.tags(dan, names);
    expect(fetcher.requests.length, 3);
    for (final request in fetcher.requests) {
      expect(query(request)['search[name_comma]']!.split(',').length, lessThanOrEqualTo(BooruClient.tagBatch));
    }
    expect(found.map((tag) => tag.name).toSet(), names.toSet());
    expect(await client.tags(dan, const []), isEmpty);
    expect(fetcher.requests.length, 3, reason: 'Nothing to ask means no request');
  });

  test('tags the server answers without being asked are dropped', () async {
    // The intruder comes between the asked rows: rows are filtered to the asked names before they are cut.
    final (client, _) = mocked(
      (_) => (200, '[{"name":"a","post_count":5,"category":0},{"name":"intruder","post_count":9,"category":0},{"name":"b","post_count":3,"category":4}]'),
    );
    final found = await client.tags(dan, ['a', 'b']);
    expect(found.map((tag) => tag.name), ['a', 'b']);
    expect(found.map((tag) => tag.category), [0, 4]);
  });

  test('Gelbooru tags use the dapi tag page with space-joined names', () async {
    final (client, fetcher) = mocked(
      (_) => (200, '{"tag":[{"name":"a","count":3,"type":0},{"name":"b","count":4,"type":4},{"name":"other","count":1,"type":0}]}'),
    );
    final found = await client.tags(gelbooruWebsite, ['b', 'a']);
    final request = fetcher.requests.first;
    expect(request.url.path.endsWith('index.php'), isTrue);
    expect(query(request)['page'], 'dapi');
    expect(query(request)['s'], 'tag');
    expect(query(request)['q'], 'index');
    expect(query(request)['json'], '1');
    expect(query(request)['names'], 'a b');
    expect(found.map((tag) => tag.name), ['a', 'b']);
    expect(found.map((tag) => tag.count), [3, 4]);
  });

  test('older Gelbooru servers are asked for one tag at a time because they ignore several names', () async {
    final (client, fetcher) = mocked(
      (_) => (
        200,
        '<?xml version="1.0" encoding="UTF-8"?><tags type="array"><tag type="0" count="362090" name="cowboy_shot" ambiguous="false" id="155086"/></tags>',
      ),
    );
    final found = await client.tags(gelbooru, ['cowboy_shot']);
    final request = fetcher.requests.first;
    expect(query(request)['name'], 'cowboy_shot');
    expect(query(request)['names'], isNull);
    expect(found.map((tag) => tag.count), [362090]);
    await expectLater(client.tags(gelbooru, ['a', 'b']), throwsA(unsupported()));
    expect(fetcher.requests.length, 1, reason: 'No request is sent for a lookup the server cannot answer');
  });

  test('Moebooru and old Gelbooru tags are unsupported and send no request', () async {
    final (client, fetcher) = mocked((_) => (200, '[]'));
    await expectLater(client.tags(moebooru, ['a']), throwsA(unsupported()));
    await expectLater(
      client.tags(BooruServer(id: 'legacy', name: 'Legacy', baseURL: 'https://legacy.example', engine: BooruEngine.oldGelbooru), ['a']),
      throwsA(unsupported()),
    );
    expect(fetcher.requests, isEmpty);
  });

  test('wiki requests the title search and reads the title, body and other names', () async {
    final (client, fetcher) = mocked(
      (_) => (200, r'[{"title":"cowboy_shot","body":"line one\r\nline two","other_names":["カウボーイショット","","牛仔镜头"],"is_deleted":false}]'),
    );
    final wiki = await client.wiki(dan, 'cowboy_shot');
    final request = fetcher.requests.first;
    expect(request.url.path.endsWith('/wiki_pages.json'), isTrue);
    expect(query(request)['search[title]'], 'cowboy_shot');
    expect(query(request)['only'], 'title,body,other_names,is_deleted');
    expect(query(request)['limit'], '1');
    expect(wiki?.title, 'cowboy_shot');
    expect(wiki?.body, 'line one\nline two');
    expect(wiki?.otherNames, ['カウボーイショット', '牛仔镜头'], reason: 'Other names are kept, empty ones are not');
  });

  test('wiki is null for an empty answer and for a deleted page', () async {
    expect(await mocked((_) => (200, '[]')).$1.wiki(dan, 'nothing'), isNull);
    expect(await mocked((_) => (200, '[{"title":"gone","body":"text","other_names":[],"is_deleted":true}]')).$1.wiki(dan, 'gone'), isNull);
    expect(
      await mocked((_) => (200, '[{"title":"bare","body":"","other_names":[]}]')).$1.wiki(dan, 'bare'),
      isNull,
      reason: 'A page with nothing on it is no page',
    );
    final later = await mocked((_) => (200, '[{"title":"gone","body":"old","is_deleted":true},{"title":"kept","body":"new","is_deleted":false}]')).$1
        .wiki(dan, 'kept');
    expect(later?.title, 'kept');
    await expectLater(mocked((_) => (200, '{"not":"a list"}')).$1.wiki(dan, 'x'), throwsA(isA<BooruError>()));
  });

  test('wiki keeps at most forty thousand characters and twenty-four other names', () async {
    final body = 'a' * 50000, names = [for (var index = 0; index < 40; index++) 'n$index'];
    final (client, _) = mocked(
      (_) => (
        200,
        jsonEncode([
          {'title': 't', 'body': body, 'other_names': names},
        ]),
      ),
    );
    final wiki = await client.wiki(dan, 't');
    expect(wiki?.body.length, 40000);
    expect(wiki?.otherNames.length, 24);
  });

  test('related tags request the query, read name, category, count and frequency and leave out the asked tag', () async {
    const body =
        '{"query":"cowboy_shot","related_tags":[{"tag":{"name":"cowboy_shot","category":0,"post_count":100},"frequency":1.0},{"tag":{"name":"smile","category":0,"post_count":500},"frequency":0.4},{"tag":{"name":"hatsune_miku","category":4,"post_count":9000},"frequency":0.25}]}';
    final (client, fetcher) = mocked((_) => (200, body));
    final related = await client.relatedTags(dan, 'cowboy_shot');
    final request = fetcher.requests.first;
    expect(request.url.path.endsWith('/related_tag.json'), isTrue);
    expect(query(request)['query'], 'cowboy_shot');
    expect(query(request)['limit'], '24');
    expect(related, const [
      StudyRelatedTag(name: 'smile', category: 0, count: 500, frequency: 0.4),
      StudyRelatedTag(name: 'hatsune_miku', category: 4, count: 9000, frequency: 0.25),
    ]);
    await expectLater(mocked((_) => (200, '[]')).$1.relatedTags(dan, 'x'), throwsA(isA<BooruError>()));
  });

  test('wiki and related tags are unsupported on servers that are not Danbooru', () async {
    final (client, fetcher) = mocked((_) => (200, '[]'));
    for (final server in [gelbooru, moebooru]) {
      await expectLater(client.wiki(server, 'a'), throwsA(unsupported()));
      await expectLater(client.relatedTags(server, 'a'), throwsA(unsupported()));
    }
    expect(fetcher.requests, isEmpty);
  });

  test('a source without tag pages throws unsupported by default', () async {
    final source = StudyFakeSource();
    await expectLater(source.tags(dan, ['a']), throwsA(unsupported()));
    await expectLater(source.wiki(dan, 'a'), throwsA(unsupported()));
    await expectLater(source.relatedTags(dan, 'a'), throwsA(unsupported()));
  });

  test('suggestions still return at most twelve by default and honour an explicit limit', () {
    Uint8List rows(int count) => Uint8List.fromList(
      utf8.encode(
        jsonEncode([
          for (var index = 0; index < count; index++) {'name': 'tag$index', 'post_count': index, 'category': 0},
        ]),
      ),
    );
    expect(BooruDecoder.suggestions(rows(30), dan).length, 12);
    expect(BooruDecoder.suggestions(rows(30), dan, limit: 30).length, 30);
    expect(BooruDecoder.suggestions(rows(30), dan, limit: 5).length, 5);
    final names = Uint8List.fromList(utf8.encode(jsonEncode([for (var index = 0; index < 20; index++) 'n$index'])));
    expect(BooruDecoder.suggestions(names, dan).length, 12);
    expect(BooruDecoder.suggestions(names, dan, limit: 20).length, 20);
  });

  test('the fixture source answers tags, wiki and related tags, and the study posts', () async {
    final source = BooruFixtureSource(options: {BooruFixtureOption.studyUITest}, delay: Duration.zero);
    expect((await source.tags(dan, ['solo'])).single.count, 4000);
    final wiki = await source.wiki(dan, 'cowboy_shot');
    expect(wiki?.body, startsWith('A synthetic page about [[cowboy shot]].'));
    expect(wiki?.otherNames, ['フィクスチャ']);
    expect((await source.relatedTags(dan, 'upper_body')).map((tag) => tag.name), ['sample_artist', 'full_body']);
    final group = bundled.groupOf('cowboy_shot')!;
    final batch = await source.posts(dan, 'cowboy_shot', 0);
    expect(batch.posts.where((value) => value.tags.first == 'cowboy_shot').length, 3);
    expect(batch.posts.length, 3 + group.tags.where((tag) => tag.name != 'cowboy_shot').take(3).length);
    expect(batch.posts.every(StudyEngine.usable), isTrue);
    expect(
      (await BooruFixtureSource(delay: Duration.zero).posts(dan, 'cowboy_shot', 0)).posts.length,
      2,
      reason: 'Without the switch the usual fixture answers',
    );
  });

  // MARK: StudyLookup

  test('shown drops blacklisted, unusable and removed posts and keeps the rest', () {
    final store = storeWith(servers: [dan]);
    store.setBlacklist('hidden_tag', serverID: dan.id);
    final posts = [
      post(1, ['solo']),
      post(2, ['solo', 'hidden_tag']),
      post(3, ['solo'], ext: 'mp4'),
      post(4, ['solo', 'animated']),
      post(5, ['solo'])..isBanned = true,
      post(6, ['solo'])
        ..previewURL = null
        ..sampleURL = null
        ..fileURL = null,
      post(7, ['1girl']),
    ];
    expect(StudyLookup.shown(posts, store: store).map((value) => value.postID), [1, 7]);
  });

  test('shown applies each servers own blacklist', () {
    final other = BooruServer(id: 'study-other', name: 'Other', baseURL: 'https://other.example', engine: BooruEngine.danbooru);
    final store = storeWith(servers: [dan, other]);
    store.setBlacklist('solo', serverID: dan.id);
    final posts = [
      post(1, ['solo']),
      BooruFixtureSource.post(2, other, tags: ['solo']),
    ];
    expect(StudyLookup.shown(posts, store: store).map((value) => value.id), ['study-other:2']);
  });

  test('shown keeps only Safebooru posts in Safe Mode', () {
    final store = storeWith(servers: [dan]);
    if (!store.servers.any((server) => server.isSafebooru)) store.saveServer(BooruServer.safebooru());
    final safe = store.servers.firstWhere((server) => server.isSafebooru);
    final posts = [
      post(1, ['solo']),
      BooruFixtureSource.post(2, safe, tags: ['solo']),
    ];
    expect(StudyLookup.shown(posts, store: store).length, 2);
    store.safeMode = () => true;
    expect(StudyLookup.shown(posts, store: store).map((value) => value.serverID), [safe.id]);
  });

  test('hurried gives up after the limit and tells an answer of null from no answer', () async {
    expect((await StudyLookup.hurried(() async => 7))?.$1, 7);
    expect((await StudyLookup.hurried<int?>(() async => null)), isNotNull, reason: 'An answer of null is still an answer');
    expect(await StudyLookup.hurried(() => Completer<int>().future, seconds: 0.05), isNull);
    expect(await StudyLookup.hurried<int>(() async => throw StateError('offline')), isNull);
    expect(await StudyLookup.hurried<int>(() => throw StateError('at once')), isNull);
  });

  test('the info server is a Danbooru one when any is chosen, else the first chosen', () {
    final store = storeWith(servers: [gelbooru, dan], select: true);
    expect(StudyLookup.infoServer(store)?.id, dan.id);
    store.setSelectedServers([gelbooru.id]);
    expect(StudyLookup.infoServer(store)?.id, gelbooru.id);
    store.setSelectedServers([]);
    expect(StudyLookup.infoServer(store), isNull);
  });

  test('info reads the three answers once, keeps them, and uses a recent answer as it is', () async {
    final store = storeWith(servers: [dan], select: true);
    final source = StudyPagesSource();
    final info = await StudyLookup.info('solo', store: store, source: source);
    expect(info?.count, 40);
    expect(info?.wiki?.body, 'About solo.');
    expect(info?.related.single.name, 'smile');
    expect(info?.complete, isTrue);
    expect(source.asked, 3);
    expect(await StudyLookup.info('solo', store: store, source: source), info);
    expect(source.asked, 3, reason: 'A recent answer kept on the device is used as it is');
    expect(store.studyStore.info('solo', address: dan.canonicalAddress), info);
    expect(
      await StudyLookup.info('solo', store: storeWith(), source: source),
      isNull,
      reason: 'No server is chosen',
    );
  });

  test('tag info is kept once complete and asked again when a page did not answer', () async {
    final store = storeWith(servers: [dan], select: true);
    final source = StudyPagesSource()..wikiFails = true;
    final partial = await StudyLookup.info('smile', store: store, source: source);
    expect(partial?.count, 40);
    expect(partial?.wiki, isNull);
    expect(partial?.complete, isFalse, reason: 'A page that did not answer is asked for again next time');
    expect(source.asked, 3);
    source.wikiFails = false;
    final retried = await StudyLookup.info('smile', store: store, source: source);
    expect(retried?.wiki, isNotNull);
    expect(retried?.complete, isTrue);
    expect(source.asked, 6);
    await StudyLookup.info('smile', store: store, source: source);
    expect(source.asked, 6, reason: 'A complete, recent answer is not asked for again');
    // A server without tag pages is complete once the count answered.
    final gelStore = storeWith(servers: [gelbooruWebsite], select: true);
    final plain = await StudyLookup.info('smile', store: gelStore, source: StudyPagesSource()..wikiFails = true);
    expect(plain?.complete, isTrue);

    // A tag the server leaves out of its answer has no posts there, and is not asked for every time.
    source.omitted.add('no_such_tag');
    final before = source.asked;
    final unknown = await StudyLookup.counts(['no_such_tag'], store: store, source: source);
    expect(unknown['no_such_tag'], 0, reason: 'A tag the server leaves out has no posts there');
    await StudyLookup.counts(['no_such_tag'], store: store, source: source);
    expect(source.asked, before + 1, reason: 'A tag the server does not know is not asked for again');
  });

  test('info keeps what was known when nothing answers, and fills a missing page from it', () async {
    final store = storeWith(servers: [dan], select: true);
    store.studyStore.save(
      StudyTagInfo(
        name: 'solo',
        count: 5,
        category: 0,
        wiki: const StudyWiki(title: 'solo', body: 'old', otherNames: []),
        related: const [],
        fetched: DateTime.now().subtract(const Duration(days: 30)),
        complete: true,
      ),
      address: dan.canonicalAddress,
    );
    final stale = await StudyLookup.info('solo', store: store, source: StudyFakeSource());
    expect(stale?.wiki?.body, 'old', reason: 'Nothing answered, so the stale answer stays');
    expect(stale?.isStale(), isTrue);
    final source = StudyPagesSource()..wikiAnswers = false;
    final renewed = await StudyLookup.info('solo', store: store, source: source);
    expect(renewed?.count, 40);
    expect(renewed?.wiki?.body, 'old', reason: 'A page the server no longer has is kept');
    expect(renewed?.isStale(), isFalse);
  });

  test('counts asks only for tags not known and keeps what was cached about each', () async {
    final store = storeWith(servers: [dan], select: true);
    store.studyStore.save(tagInfo('solo', count: 12), address: dan.canonicalAddress);
    final source = StudyPagesSource();
    final known = await StudyLookup.counts(['solo', '1girl', 'smile'], store: store, source: source);
    expect(known, {'solo': 12, '1girl': 40, 'smile': 40});
    expect(source.asked, 1, reason: 'One request for the tags not known');
    expect(store.studyStore.info('1girl', address: dan.canonicalAddress)?.complete, isFalse, reason: 'Only the count is known');
    expect(store.studyStore.info('solo', address: dan.canonicalAddress)?.wiki?.body, 'body', reason: 'What was cached stays');
    expect(await StudyLookup.counts(['solo', '1girl'], store: store, source: source), {'solo': 12, '1girl': 40, 'smile': 40});
    expect(source.asked, 1);
    expect(await StudyLookup.counts(['solo'], store: storeWith(), source: source), isEmpty);
  });

  // MARK: StudySession

  test('a session asks, records each answer and finishes with results and the right count', () async {
    final store = storeWith(servers: [dan], select: true);
    final session = StudySession(scope: const StudyScope.tags(['s1', 's2']), store: store, source: StudyFakeSource(), engine: tinyEngine(), random: Random(1));
    addTearDown(session.dispose);
    var changes = 0;
    session.addListener(() => changes += 1);
    expect(session.phase, StudyPhase.loading);
    await session.start();
    expect(session.phase, StudyPhase.asking);
    expect(changes, greaterThan(0));
    final first = session.question!;
    expect(first.tag.name, 's1');
    expect(session.tags.map((tag) => tag.name), ['s1', 's2']);

    session.choose(first.answer);
    expect(session.phase, StudyPhase.answered(first.answer));
    expect(session.results.map((result) => result.right), [true]);
    final stored = store.studyStore.progress();
    expect(stored['s1']?.step, 1);
    expect(stored['s1']?.correct, 1);
    final days = store.studyStore.days();
    expect(days.length, 1);
    expect(days.first.answered, 1);
    expect(days.first.correct, 1);
    session.choose(0);
    expect(session.results.length, 1, reason: 'An answered question cannot be answered again');

    await session.advance();
    expect(session.phase, StudyPhase.asking);
    final second = session.question!;
    expect(second.tag.name, 's2');
    final wrong = (second.answer + 1) % second.choiceCount;
    session.choose(wrong);
    expect(session.phase, StudyPhase.answered(wrong));
    expect(store.studyStore.progress()['s2']?.wrong, 1);
    expect(store.studyStore.days().first.answered, 2);
    expect(store.studyStore.days().first.correct, 1);

    await session.advance();
    expect(session.phase, StudyPhase.finished);
    expect(session.question, isNull);
    expect(session.results.map((result) => result.tag.name), ['s1', 's2']);
    expect(session.results.map((result) => result.right), [true, false]);
    expect(session.rightCount, 1);
    await session.advance();
    expect(session.phase, StudyPhase.finished, reason: 'A finished session stays finished');
  });

  test('a session asks by meaning when the server cannot be read and says it had no pictures', () async {
    final store = storeWith(servers: [dan], select: true);
    final session = StudySession(
      scope: const StudyScope.tags(['s1', 's2']),
      store: store,
      source: StudyFakeSource(failing: true),
      engine: tinyEngine(),
      random: Random(2),
    );
    addTearDown(session.dispose);
    await session.start();
    expect(session.phase, StudyPhase.asking);
    expect(session.question?.kind, StudyQuestionKind.meaningToTag);
    expect(session.withoutPictures, isTrue);
    final question = session.question!;
    expect(question.choices[question.answer].name, 's1');
    session.choose(question.answer);
    await session.advance();
    expect(session.question?.kind, StudyQuestionKind.meaningToTag);
  });

  test('a session with pictures offers them, and does not show one twice while others remain', () async {
    final store = storeWith(servers: [dan], select: true);
    for (var seed = 0; seed < 8; seed++) {
      final session = StudySession(
        scope: const StudyScope.tags(['s1', 's2', 's3']),
        store: store,
        source: StudyFakeSource(),
        engine: tinyEngine(),
        random: Random(seed),
        records: false,
      );
      await session.start();
      final shown = <String>[];
      while (session.phase == StudyPhase.asking) {
        shown.addAll(session.question!.posts.map((value) => value.id));
        session.choose(session.question!.answer);
        await session.advance();
      }
      expect(session.phase, StudyPhase.finished);
      expect(session.withoutPictures, isFalse, reason: 'seed $seed');
      expect(shown.length, shown.toSet().length, reason: 'seed $seed');
      session.dispose();
    }
  });

  test('a session without a chosen server asks by meaning without claiming pictures were missing', () async {
    final store = storeWith();
    expect(store.selectedServers, isEmpty);
    final session = StudySession(scope: const StudyScope.tags(['s1']), store: store, source: StudyFakeSource(), engine: tinyEngine(), random: Random(3));
    addTearDown(session.dispose);
    await session.start();
    expect(session.question?.kind, StudyQuestionKind.meaningToTag);
    expect(session.withoutPictures, isFalse);
  });

  test('a session that does not record writes nothing', () async {
    final store = storeWith(servers: [dan], select: true);
    final session = StudySession(
      scope: const StudyScope.tags(['s1', 's2']),
      store: store,
      source: StudyFakeSource(),
      engine: tinyEngine(),
      records: false,
      random: Random(4),
    );
    addTearDown(session.dispose);
    await session.start();
    session.choose(session.question!.answer);
    await session.advance();
    session.choose(session.question!.answer);
    await session.advance();
    expect(session.phase, StudyPhase.finished);
    expect(session.rightCount, 2);
    expect(store.studyStore.progress(), isEmpty);
    expect(store.studyStore.days(), isEmpty);
  });

  test('a session with no tags to study finishes at once', () async {
    final session = StudySession(scope: const StudyScope.tags(['not_taught']), store: storeWith(), source: StudyFakeSource(), engine: tinyEngine());
    addTearDown(session.dispose);
    await session.start();
    expect(session.phase, StudyPhase.finished);
    expect(session.question, isNull);
    expect(session.results, isEmpty);
  });

  test('a session starts its round from the stored progress', () async {
    final store = storeWith();
    final now = DateTime.now();
    store.studyStore.answer('t1', right: true, now: now.subtract(const Duration(days: 3)));
    final session = StudySession(scope: StudyScope.review, store: store, source: StudyFakeSource(), engine: roundEngine(), random: Random(5));
    addTearDown(session.dispose);
    await session.start();
    expect(session.tags.map((tag) => tag.name), ['t1'], reason: 'One day after the first answer it was due again');
    expect(session.phase, StudyPhase.asking);
  });
}
