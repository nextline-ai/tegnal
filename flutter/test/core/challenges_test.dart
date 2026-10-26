import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:tegnal/core/challenges.dart';
import 'package:tegnal/core/content.dart';
import 'package:tegnal/data/library_store.dart';

void main() {
  final now = DateTime.utc(2026, 10, 26, 12);

  test(
    'weighted reels, filters and support groups render tokens exactly once',
    () {
      final json = ChallengeDefinition.croquis().toJson();
      final reels = json['reels'] as List;
      final subject = reels.first as Map;
      subject['filter'] = 'eligible';
      subject['options'] = [
        {
          'id': 'disabled',
          'text': 'Disabled',
          'enabled': false,
          'weight': 1000,
          'group': 'eligible',
          'tags': [],
        },
        {
          'id': 'filtered',
          'text': 'Filtered',
          'enabled': true,
          'weight': 1000,
          'group': 'other',
          'tags': [],
        },
        {
          'id': 'eligible',
          'text': '{reel2}',
          'enabled': true,
          'weight': 2,
          'group': 'eligible',
          'tags': ['solo'],
        },
      ];
      json['groups'] = [
        {
          'id': 'extra',
          'title': 'Extra',
          'filter': '',
          'options': [
            {
              'id': 'extra-option',
              'text': 'Extra choice',
              'enabled': true,
              'weight': 1,
              'group': '',
              'tags': ['solo', 'scenery'],
            },
          ],
        },
      ];
      json['template'] = '{reel1} / {reel2} / {extra1} / {goal}';
      final session = ChallengeSession(ChallengeDefinition.fromJson(json));
      ChallengeEngine(random: (_) => 0).draw(session);
      expect(session.phase, ChallengePhase.spinning);
      expect(
        session.mission!.text,
        '{reel2} / Outline / Extra choice / 30 seconds',
      );
      expect(session.mission!.tags, ['scenery', 'solo']);
      expect(session.mission!.selections.first['id'], 'eligible');
    },
  );

  test(
    'weighted mixed goal selection and stepped ranges use supplied randomness',
    () {
      final json = ChallengeDefinition.croquis().toJson();
      final goal = json['goal'] as Map;
      goal['mode'] = 'mixed';
      final picks = [3, 2, 99, 2];
      final engine = ChallengeEngine(
        random: (maximum) {
          final value = picks.removeAt(0);
          expect(value, lessThan(maximum));
          return value;
        },
      );
      final session = ChallengeSession(ChallengeDefinition.fromJson(json));
      engine.draw(session);
      expect(session.mission!.selections.first['id'], 'object');
      expect(session.mission!.kind, ChallengeGoalKind.count);
      expect(session.mission!.goal, 3);
      expect(session.remaining, 0);
      expect(picks, isEmpty);
    },
  );

  test('deadline timer survives restore, pauses accurately and awards only when ready', () {
    final engine = ChallengeEngine(random: (_) => 0);
    var session = ChallengeSession(ChallengeDefinition.croquis());
    engine.draw(session);
    engine.reveal(session);
    engine.complete(session, now);
    expect(session.score, 0);
    engine.toggleTimer(session, now);
    session = ChallengeSession.fromJson(session.toJson());
    engine.reconcile(
      session,
      now.add(const Duration(seconds: 5)),
      restore: true,
    );
    expect(session.remaining, 25);
    engine.toggleTimer(session, now.add(const Duration(seconds: 5)));
    expect(session.deadline, isNull);
    expect(engine.seconds(session, now.add(const Duration(hours: 1))), 25);
    engine.toggleTimer(session, now.add(const Duration(seconds: 10)));
    engine.reconcile(session, now.add(const Duration(seconds: 35)));
    expect(session.phase, ChallengePhase.ready);
    engine.complete(session, now.add(const Duration(seconds: 35)));
    expect(session.score, 12);
    expect(session.phase, ChallengePhase.idle);
    engine.complete(session, now.add(const Duration(seconds: 36)));
    expect(session.score, 12);
  });

  test(
    'count goals, score bands, multiplier and fixed ending match native rules',
    () {
      final json = ChallengeDefinition.croquis().toJson();
      (json['goal'] as Map)['mode'] = 'count';
      json['target'] = 10;
      json['multiplier'] = .5;
      json['bands'] = [
        {'id': 'band', 'through': 10, 'minimum': 19, 'maximum': 19},
      ];
      json['fixedEndingID'] = 'momentum';
      final session = ChallengeSession(ChallengeDefinition.fromJson(json));
      final engine = ChallengeEngine(random: (_) => 0);
      engine.draw(session);
      engine.reveal(session);
      engine.adjust(session, 1);
      expect(session.phase, ChallengePhase.ready);
      engine.adjust(session, -1);
      expect(session.phase, ChallengePhase.active);
      engine.adjust(session, 100);
      expect(session.count, 1);
      engine.complete(session, now);
      expect(session.score, 10);
      expect(session.phase, ChallengePhase.ended);
      expect(session.ending!['id'], 'momentum');
      engine.complete(session, now);
      expect(session.score, 10);
    },
  );

  test(
    'validates atomic tags, stepped ranges, variables and scoring coverage',
    () {
      for (final invalid in [
        (Map<String, dynamic> value) =>
            ((value['reels'] as List).first['options'] as List).first['tags'] =
                ['rating:explicit'],
        (Map<String, dynamic> value) =>
            ((value['goal'] as Map)['time'] as Map)['step'] = 7,
        (Map<String, dynamic> value) => value['template'] = '{unsupported}',
        (Map<String, dynamic> value) => value['target'] = 200,
      ]) {
        final json = ChallengeDefinition.croquis().toJson();
        invalid(json);
        expect(
          () => ChallengeDefinition.fromJson(json),
          throwsA(isA<ContentException>()),
        );
      }
    },
  );

  test('native-compatible backup definitions retain fields while sessions stay local', () {
    final store = LibraryStore.memory();
    addTearDown(store.database.close);
    final repository = ChallengeRepository(store);
    final definition = ChallengeDefinition.croquis().withChanges({
      'futureField': {'preserve': true},
      'helpPages': [
        {'id': 'tips', 'title': 'Tips', 'body': 'Keep drawing.'},
      ],
    });
    repository.save(definition);
    var session = ChallengeSession(definition)
      ..sourceKind = 'folder'
      ..folderId = 'private-folder'
      ..serverIds = ['private-server'];
    final engine = ChallengeEngine(random: (_) => 0);
    engine.draw(session);
    session = repository.commit(session, expected: 0);
    final exported = repository.exportJson();
    expect(exported, isNot(contains('private-folder')));
    expect(exported, isNot(contains('private-server')));
    final envelope = jsonDecode(exported) as Map;
    expect(envelope['format'], 'tegnal-challenges');
    expect(envelope['schemaVersion'], 1);
    expect(
      (store.portable('backup.challenges')!['games'] as List)
          .single['futureField'],
      {'preserve': true},
    );
    expect(repository.session(definition).folderId, 'private-folder');
    expect(repository.session(definition).mission!.text, session.mission!.text);
    expect(repository.session(definition).revision, 1);
  });

  test('stale commits cannot award twice and deleting definition clears local session', () {
    final store = LibraryStore.memory();
    addTearDown(store.database.close);
    final repository = ChallengeRepository(store);
    final definition = repository.example();
    final first = repository.session(definition);
    final otherWindow = repository.session(definition);
    final engine = ChallengeEngine(random: (_) => 0);
    engine.draw(first);
    repository.commit(first, expected: 0);
    engine.draw(otherWindow);
    expect(
      () => repository.commit(otherWindow, expected: 0),
      throwsA(isA<ContentException>()),
    );
    expect(repository.hasSession(definition.id), isTrue);
    repository.delete(definition.id);
    expect(repository.hasSession(definition.id), isFalse);
    expect(repository.definitions(), isEmpty);
  });

  test('import validates all definitions before writing and duplicates collisions by default', () {
    final store = LibraryStore.memory();
    addTearDown(store.database.close);
    final repository = ChallengeRepository(store);
    final definition = repository.example();
    final text = repository.exportJson();
    repository.importJson(text);
    expect(repository.definitions().length, 2);
    expect(repository.definitions().map((value) => value.id).toSet().length, 2);
    final bad = jsonDecode(text) as Map;
    final invalid = definition.toJson()
      ..['id'] = 'new-id'
      ..['template'] = '{invalid}';
    bad['games'] = [definition.toJson(), invalid];
    expect(
      () => repository.importJson(jsonEncode(bad)),
      throwsA(isA<ContentException>()),
    );
    expect(repository.definitions().length, 2);
    repository.importJson(
      text.replaceFirst('tegnal-challenges', 'number-memo-challenges'),
      replace: true,
    );
    expect(repository.definitions().length, 2);
  });
}
