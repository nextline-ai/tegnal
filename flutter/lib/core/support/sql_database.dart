import 'dart:async';
import 'dart:typed_data';

import 'package:sqlite3/sqlite3.dart' as sqlite;

/// A synchronous SQLite connection with the transaction behavior of a GRDB
/// `DatabaseQueue`: `write` runs in one transaction, and an error in its body
/// rolls the whole body back. Nested writes join the enclosing transaction.
class SqlDatabase {
  SqlDatabase._(this._db) {
    // GRDB enables foreign keys on every connection by default.
    _db.execute('PRAGMA foreign_keys = ON');
  }

  factory SqlDatabase.open(String path) => SqlDatabase._(sqlite.sqlite3.open(path));
  factory SqlDatabase.inMemory() => SqlDatabase._(sqlite.sqlite3.openInMemory());

  /// Another app's database, read without changing it (`Configuration.readonly`).
  factory SqlDatabase.openReadOnly(String path) => SqlDatabase._(sqlite.sqlite3.open(path, mode: sqlite.OpenMode.readOnly));

  final sqlite.Database _db;
  int _depth = 0;
  final _changes = StreamController<int>.broadcast();

  /// Counts committed writes. Screens that list library rows observe [changes] and fetch
  /// again, standing in for GRDB's `ValueObservation`, which re-runs a query after each
  /// committed transaction that may have changed it.
  int revision = 0;

  /// The new [revision] after every committed `write`, delivered asynchronously.
  Stream<int> get changes => _changes.stream;

  /// Rows changed by the last INSERT, UPDATE or DELETE (`db.changesCount`).
  int get changesCount => _db.updatedRows;
  int get lastInsertedRowID => _db.lastInsertRowId;

  T read<T>(T Function(SqlDatabase db) body) => body(this);

  T write<T>(T Function(SqlDatabase db) body) {
    if (_depth > 0) {
      _depth += 1;
      try {
        return body(this);
      } finally {
        _depth -= 1;
      }
    }
    _db.execute('BEGIN IMMEDIATE');
    _depth = 1;
    try {
      final result = body(this);
      _db.execute('COMMIT');
      revision += 1;
      _changes.add(revision);
      return result;
    } catch (_) {
      _db.execute('ROLLBACK');
      rethrow;
    } finally {
      _depth = 0;
    }
  }

  /// Without arguments the SQL may hold several statements.
  void execute(String sql, [List<Object?> arguments = const []]) => _db.execute(sql, _bind(arguments));

  List<Map<String, Object?>> rows(String sql, [List<Object?> arguments = const []]) {
    final result = _db.select(sql, _bind(arguments));
    return [for (final row in result) Map<String, Object?>.of(row)];
  }

  Map<String, Object?>? row(String sql, [List<Object?> arguments = const []]) {
    final all = rows(sql, arguments);
    return all.isEmpty ? null : all.first;
  }

  /// The first column of every row.
  List<T> column<T>(String sql, [List<Object?> arguments = const []]) {
    final result = _db.select(sql, _bind(arguments));
    return [for (final row in result) _cast<T>(row.columnAt(0))];
  }

  /// The first column of the first row, or null.
  T? value<T>(String sql, [List<Object?> arguments = const []]) {
    final result = _db.select(sql, _bind(arguments));
    if (result.isEmpty) return null;
    final value = result.first.columnAt(0);
    return value == null ? null : _cast<T>(value);
  }

  bool exists(String sql, [List<Object?> arguments = const []]) => value<bool>(sql, arguments) == true;

  bool tableExists(String name) => value<int>("SELECT COUNT(*) FROM sqlite_master WHERE type = 'table' AND name = ?", [name])! > 0;

  List<String> columns(String table) => [for (final row in rows('PRAGMA table_info("$table")')) row['name'] as String];

  void close() {
    _db.close();
    _changes.close();
  }

  static List<Object?> _bind(List<Object?> arguments) => [for (final value in arguments) value is bool ? (value ? 1 : 0) : value];

  static T _cast<T>(Object? value) {
    if (T == bool) return (value is int ? value != 0 : value) as T;
    if (T == double && value is int) return value.toDouble() as T;
    if (T == Uint8List && value is String) return Uint8List.fromList(value.codeUnits) as T;
    return value as T;
  }
}

/// Runs each registered migration once, in its own transaction, recording it in
/// the same table GRDB uses so both apps name a schema version the same way.
class SqlMigrator {
  final _migrations = <(String, void Function(SqlDatabase db))>[];

  void registerMigration(String identifier, void Function(SqlDatabase db) migrate) => _migrations.add((identifier, migrate));

  void migrate(SqlDatabase database) {
    database.execute('CREATE TABLE IF NOT EXISTS grdb_migrations (identifier TEXT NOT NULL PRIMARY KEY)');
    final applied = database.column<String>('SELECT identifier FROM grdb_migrations').toSet();
    for (final (identifier, migrate) in _migrations) {
      if (applied.contains(identifier)) continue;
      database.write((db) {
        migrate(db);
        db.execute('INSERT INTO grdb_migrations VALUES (?)', [identifier]);
      });
    }
  }
}
