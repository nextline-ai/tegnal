// Ported from native-ios/TEGNALTests/ChallengeTests.swift: the definition, backup
// and restore tests. Session and engine tests arrive with the challenge screens (step 7).
import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:tegnal/core/booru/booru_store.dart';
import 'package:tegnal/core/challenge/challenge_models.dart';
import 'package:tegnal/core/challenge/challenge_store.dart';
import 'package:tegnal/core/support/swift_json.dart';

import '../../support/backup_fixtures.dart';

void main() {
  test('historical backup imports and reexports with current format', () {
    final original = testGame();
    final current = ChallengeBackup(games: [original]).encoded();
    final historical = utf8.decode(current).replaceAll('tegnal-challenges', 'number-memo-challenges');
    final decoded = ChallengeBackup.decode(utf8.encode(historical));
    expect(decoded.format, 'tegnal-challenges');
    expect(decoded.games.map(gameJson), [gameJson(original)]);
    final exported = decodeJsonObject(decoded.encoded());
    expect(exported['format'], 'tegnal-challenges');
    final invalid = decoded..format = 'unrelated-challenges';
    expect(() => ChallengeBackup.decode(utf8.encode(jsonEncode(invalid.toJson()))), throwsA(isA<ChallengeError>()));
  });

  test('validation rejects invalid rules and executable variables', () {
    final original = testGame();
    final invalid = <void Function(ChallengeDefinition value)>[
      (value) => value.reels.removeLast(),
      (value) => value.reels[0].options.clear(),
      (value) => value.reels[0].options[0].enabled = false,
      (value) => value.reels[0].filter = 'missing',
      (value) => value.reels[0].options[0].weight = 0,
      (value) => value.reels[0].options[0].tags = ['rating:explicit'],
      (value) => value.goal.time = ChallengeRange(minimum: value.goal.time.minimum, maximum: value.goal.time.maximum, step: 0),
      (value) => value.goal.time = ChallengeRange(minimum: value.goal.time.minimum, maximum: 119, step: value.goal.time.step),
      (value) => value.target = 1000,
      (value) => value.bands = value.bands.reversed.toList(),
      (value) => value.bands[0].maximum = -1,
      (value) => value.endings.clear(),
      (value) => value.endings[0].weight = -1,
      (value) => value.fixedEndingID = 'missing',
      (value) => value.template = '{unknown}',
      (value) => value.template = '{reel1',
      (value) => value.template = '{{reel1}}',
      (value) => value.multiplier = double.infinity,
      (value) => value.reels[0].options.add(value.reels[0].options[0]),
    ];
    for (final mutate in invalid) {
      final value = copyGame(original);
      mutate(value);
      expect(value.validate, throwsA(isA<ChallengeError>()));
    }
    original.validate();
  });

  test('backup round trip limits and unsupported version', () {
    final backup = ChallengeBackup(games: [testGame()]);
    final data = backup.encoded();
    expect(ChallengeBackup.decode(data).games.map(gameJson), backup.games.map(gameJson));
    final text = utf8.decode(data);
    for (final privateKey in ['deadline', 'selectedPost', 'serverIDs', 'apiKey', 'cookie', 'revision']) {
      expect(text.contains('"$privateKey"'), isFalse);
    }
    final future = ChallengeBackup.fromJson(decodeJsonObject(data))..schemaVersion = 2;
    expect(() => ChallengeBackup.decode(utf8.encode(jsonEncode(future.toJson()))), throwsA(isA<ChallengeError>()));
    expect(() => ChallengeBackup.decode(List.filled(ChallengeBackup.maximumBytes + 1, 32)), throwsA(isA<ChallengeError>()));
    expect(() => ChallengeBackup.decode(utf8.encode('{}')), throwsA(anything));
    expect(() => ChallengeBackup(games: [backup.games[0], backup.games[0]]).validate(), throwsA(isA<ChallengeError>()));
  });

  test('atomic restore and collision modes', () {
    final store = ChallengeStore(BooruStore.inMemory()), original = testGame();
    store.save(original);
    final edited = copyGame(original)..title = 'Edited';
    store.restore(ChallengeBackup(games: [edited]), replace: false);
    expect(store.definitions().length, 2);
    expect(store.definitions().firstWhere((game) => game.id == original.id).title, original.title);
    store.restore(ChallengeBackup(games: [edited]), replace: true);
    expect(store.definitions().firstWhere((game) => game.id == original.id).title, 'Edited');
    final invalid = testGame()..title = '';
    final before = store.definitions().map(gameJson).toList();
    expect(() => store.restore(ChallengeBackup(games: [testGame(), invalid]), replace: true), throwsA(isA<ChallengeError>()));
    expect(store.definitions().map(gameJson), before);
  });
}
