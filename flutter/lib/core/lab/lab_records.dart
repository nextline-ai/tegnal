import 'dart:convert';

import '../support/sql_database.dart';

// The AI lab's progress as rows of the image database's `lab_records` table, so it travels in sync and backups.
// Ported from `LabRecords.swift`; both apps write the same keys.

/// One fact about the lab.
///
/// Keys: `card:<episode>` (engraved), `fail:<id>` (망작 hung), `edition:<id>` (value = 연구비 paid), `purchase:<item>`
/// (value = count, text = `{"price":…,"baseline":…}`), and `state:type` (text = type id), `state:greeted`,
/// `state:grandfathered`, `state:seenEdition` (text). Merging two devices keeps the larger value and the earlier time.
class LabRecord {
  const LabRecord({required this.key, required this.value, this.text, required this.at});
  final String key;
  final int value;
  final String? text;

  /// Seconds since 1970, whole.
  final double at;

  @override
  bool operator ==(Object other) => other is LabRecord && other.key == key && other.value == value && other.text == text && other.at == at;
  @override
  int get hashCode => Object.hash(key, value, text, at);
}

/// Where the lab keeps its records.
abstract class LabRecordStore {
  List<LabRecord> all();

  /// Makes the stored records exactly these, writing only what changed.
  void replace(List<LabRecord> records);
}

/// The records in the image database.
class LabDatabaseRecords implements LabRecordStore {
  LabDatabaseRecords(this.database);
  final SqlDatabase database;

  static void migrate(SqlDatabase db) {
    db.execute('CREATE TABLE lab_records (key TEXT PRIMARY KEY NOT NULL, value INTEGER NOT NULL DEFAULT 0, text TEXT, at DOUBLE NOT NULL)');
  }

  static LabRecord _record(Map<String, Object?> row) =>
      LabRecord(key: row['key']! as String, value: row['value']! as int, text: row['text'] as String?, at: (row['at']! as num).toDouble());

  @override
  List<LabRecord> all() => database.read((db) => [for (final row in db.rows('SELECT key, value, text, at FROM lab_records')) _record(row)]);

  @override
  void replace(List<LabRecord> records) => database.write((db) {
    final existing = {for (final row in db.rows('SELECT key, value, text, at FROM lab_records')) row['key']! as String: _record(row)};
    final keys = {for (final record in records) record.key};
    for (final key in existing.keys) {
      if (!keys.contains(key)) db.execute('DELETE FROM lab_records WHERE key = ?', [key]);
    }
    for (final record in records) {
      if (existing[record.key] == record) continue;
      db.execute(
        '''
        INSERT INTO lab_records (key, value, text, at) VALUES (?, ?, ?, ?)
        ON CONFLICT(key) DO UPDATE SET value = excluded.value, text = excluded.text, at = excluded.at
        ''',
        [record.key, record.value, record.text, record.at],
      );
    }
  });
}

/// Records kept in memory, for tests and before the database is reached.
class LabMemoryRecords implements LabRecordStore {
  final Map<String, LabRecord> _records = {};
  @override
  List<LabRecord> all() => _records.values.toList();
  @override
  void replace(List<LabRecord> records) => _records
    ..clear()
    ..addEntries(records.map((record) => MapEntry(record.key, record)));
}

/// What was bought.
class LabPurchase {
  const LabPurchase({required this.price, required this.count, required this.date, this.baseline});

  /// What it cost, so a later price change does not move the balance.
  final int price;
  final int count;

  /// Seconds since 1970.
  final double date;

  /// For a course: how many of its lessons were finished when it was bought. Only lessons after that pay.
  final int? baseline;

  LabPurchase copyWith({int? count, double? date, int? baseline}) =>
      LabPurchase(price: price, count: count ?? this.count, date: date ?? this.date, baseline: baseline ?? this.baseline);

  @override
  bool operator ==(Object other) => other is LabPurchase && other.price == price && other.count == count && other.date == date && other.baseline == baseline;
  @override
  int get hashCode => Object.hash(price, count, date, baseline);
}

/// Everything a learner has done in the lab, read from and written to its records. Times are seconds since 1970.
class LabProgress {
  LabProgress();

  /// Engraved cards, by episode id.
  final Map<String, double> cards = {};

  /// 망작 hung in the gallery, by fail id.
  final Map<String, double> fails = {};

  /// Cheat-sheet editions read, by edition id, with what each paid.
  final Map<String, int> editions = {};

  /// The newest edition the learner has looked at.
  String? seenEdition;

  /// What was bought, by shop item id.
  final Map<String, LabPurchase> purchases = {};

  /// The diagnosis type on card No. 000.
  String? type;
  double? diagnosed;

  /// True once the welcome check has been offered, taken or skipped.
  bool greeted = false;

  /// True once a learner who already had tag-study progress was given that course.
  bool grandfathered = false;

  factory LabProgress.fromRecords(Iterable<LabRecord> records) {
    final progress = LabProgress();
    for (final record in records) {
      final split = record.key.indexOf(':');
      if (split < 0) continue;
      final kind = record.key.substring(0, split), id = record.key.substring(split + 1);
      switch (kind) {
        case 'card':
          progress.cards[id] = record.at;
        case 'fail':
          progress.fails[id] = record.at;
        case 'edition':
          progress.editions[id] = record.value;
        case 'purchase':
          Map<String, Object?>? detail;
          try {
            final decoded = record.text == null ? null : jsonDecode(record.text!);
            if (decoded is Map) detail = decoded.cast<String, Object?>();
          } on Object {
            detail = null;
          }
          progress.purchases[id] = LabPurchase(
            price: (detail?['price'] as num?)?.toInt() ?? 0,
            count: record.value,
            date: record.at,
            baseline: (detail?['baseline'] as num?)?.toInt(),
          );
        case 'state':
          switch (id) {
            case 'type':
              progress.type = record.text;
              progress.diagnosed = record.at;
            case 'greeted':
              progress.greeted = record.value > 0;
            case 'grandfathered':
              progress.grandfathered = record.value > 0;
            case 'seenEdition':
              progress.seenEdition = record.text;
          }
      }
    }
    return progress;
  }

  List<LabRecord> get records => [
    for (final entry in cards.entries) LabRecord(key: 'card:${entry.key}', value: 1, at: entry.value),
    for (final entry in fails.entries) LabRecord(key: 'fail:${entry.key}', value: 1, at: entry.value),
    // Editions have no date of their own here; the day in the id is enough to order them.
    for (final entry in editions.entries) LabRecord(key: 'edition:${entry.key}', value: entry.value, at: 0),
    for (final entry in purchases.entries)
      LabRecord(
        key: 'purchase:${entry.key}',
        value: entry.value.count,
        text: entry.value.baseline == null ? '{"price":${entry.value.price}}' : '{"price":${entry.value.price},"baseline":${entry.value.baseline}}',
        at: entry.value.date,
      ),
    if (type != null) LabRecord(key: 'state:type', value: 1, text: type, at: diagnosed ?? 0),
    if (greeted) const LabRecord(key: 'state:greeted', value: 1, at: 0),
    if (grandfathered) const LabRecord(key: 'state:grandfathered', value: 1, at: 0),
    if (seenEdition != null) LabRecord(key: 'state:seenEdition', value: 1, text: seenEdition, at: 0),
  ];

  /// The same progress, as a set of records, for telling whether anything changed.
  Set<LabRecord> get _signature => records.toSet();

  @override
  bool operator ==(Object other) {
    if (other is! LabProgress) return false;
    final mine = _signature, theirs = other._signature;
    return mine.length == theirs.length && mine.containsAll(theirs);
  }

  @override
  int get hashCode => Object.hashAllUnordered(_signature);
}
