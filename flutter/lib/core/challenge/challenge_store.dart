import 'dart:typed_data';

import 'package:characters/characters.dart';

import '../booru/booru_store.dart';
import '../support/l10n.dart';
import '../support/sql_database.dart';
import '../support/swift_json.dart';
import 'challenge_models.dart';

/// Saved challenges live in the image library. Sessions arrive with the challenge screens.
class ChallengeStore {
  ChallengeStore(BooruStore booru) : database = booru.database;
  final SqlDatabase database;

  static void migrate(SqlDatabase db) => db.execute('''
    CREATE TABLE challenges (id TEXT PRIMARY KEY NOT NULL, payload BLOB NOT NULL);
    CREATE TABLE challenge_sessions (id TEXT PRIMARY KEY NOT NULL, payload BLOB NOT NULL);
    ''');

  List<ChallengeDefinition> definitions() => database.read(
    (db) => db.column<Uint8List>('SELECT payload FROM challenges ORDER BY rowid').map((data) => ChallengeDefinition.fromJson(decodeJsonObject(data))).toList(),
  );

  ChallengeDefinition example() => database.write((db) {
    final data = db.value<Uint8List>('SELECT payload FROM challenges WHERE id = ?', [ChallengeDefinition.exampleID]);
    if (data != null) return ChallengeDefinition.fromJson(decodeJsonObject(data));
    final game = ChallengeDefinition.croquis()..id = ChallengeDefinition.exampleID;
    write(game, db);
    return game;
  });

  Set<String> sessionIDs() => database.read((db) => db.column<String>('SELECT id FROM challenge_sessions').toSet());

  void save(ChallengeDefinition game) {
    game.validate();
    database.write((db) => write(game, db));
  }

  static void write(ChallengeDefinition game, SqlDatabase db) {
    final data = encodeSwiftJson(game.toJson());
    if (data.length > ChallengeBackup.maximumBytes) throw const ChallengeError.unsupported();
    db.execute('INSERT INTO challenges (id, payload) VALUES (?, ?) ON CONFLICT(id) DO UPDATE SET payload = excluded.payload', [game.id, data]);
  }

  void delete(String id) => database.write((db) {
    db.execute('DELETE FROM challenges WHERE id = ?', [id]);
    db.execute('DELETE FROM challenge_sessions WHERE id = ?', [id]);
  });

  void restore(ChallengeBackup backup, {required bool replace}) {
    backup.validate();
    database.write((db) {
      for (final source in backup.games) {
        final game = ChallengeDefinition.fromJson(source.toJson());
        if (!replace && db.exists('SELECT EXISTS(SELECT 1 FROM challenges WHERE id = ?)', [game.id])) {
          game.id = uuidString();
          final suffix = ' ${L10n.text('Copy')}';
          game.title = game.title.characters.take(200 - suffix.characters.length).toString() + suffix;
        }
        game.validate();
        write(game, db);
      }
    });
  }
}
