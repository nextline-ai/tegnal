import 'dart:convert';

import '../support/sql_database.dart';

// The AI lab's progress as rows of the image database's `lab_records` table, so it travels in sync and backups.
// Ported from `LabRecords.swift`; both apps write the same keys.

/// One fact about the lab.
///
/// Keys: `card:<episode>` and `fail:<id>` (engraved, hung; value = 보석 paid, or 1 when it paid nothing or was written before
/// amounts were kept), `season:<number>`, `edition:<id>`, `lesson:<course>/<lesson>`, `stars:<course>/<lesson>` and
/// `section:<course>/<section>` (value = 보석 paid), `purchase:<item>` (value = count, text = `{"price":…}`), and `state:type` (text = type id), `state:greeted`,
/// `state:legacyNoticed`, `state:seenEdition` (text). Merging two devices keeps the larger value and the earlier time.
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
  const LabPurchase({required this.price, required this.count, required this.date});

  /// What it cost, so a later price change does not move the balance.
  final int price;
  final int count;

  /// Seconds since 1970.
  final double date;

  LabPurchase copyWith({int? count, double? date}) => LabPurchase(price: price, count: count ?? this.count, date: date ?? this.date);

  /// The record's text, written the same way by both apps.
  String get detail => '{"price":$price}';

  @override
  bool operator ==(Object other) => other is LabPurchase && other.price == price && other.count == count && other.date == date;
  @override
  int get hashCode => Object.hash(price, count, date);
}

/// Everything a learner has done in the lab, read from and written to its records. Times are seconds since 1970.
class LabProgress {
  LabProgress();

  /// Engraved cards, by episode id.
  final Map<String, double> cards = {};

  /// 망작 hung in the gallery, by fail id.
  final Map<String, double> fails = {};

  /// The 보석 each card and 망작 paid when it was earned, by the same ids. Kept so that a later change to the amounts in the
  /// course files never moves a balance already earned. Missing for records written before amounts were kept: those count at
  /// the course's present amount.
  final Map<String, int> cardGems = {};
  final Map<String, int> failGems = {};

  /// The 보석 each finished season of the AI lab paid, by season number.
  final Map<String, int> seasonGems = {};

  /// The 보석 2D AI 배우기 paid, by record key: `lesson:<course>/<lesson>` (finished), `stars:<course>/<lesson>` (three stars) and
  /// `section:<course>/<section>` (every lesson finished). Each pays once; resetting the course's progress takes nothing back.
  final Map<String, int> coursePaid = {};

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

  /// True once a learner who studied 2D AI 배우기 before it was sold has been told the course now opens from the shop.
  bool legacyNoticed = false;

  factory LabProgress.fromRecords(Iterable<LabRecord> records) {
    final progress = LabProgress();
    for (final record in records) {
      final split = record.key.indexOf(':');
      if (split < 0) continue;
      final kind = record.key.substring(0, split), id = record.key.substring(split + 1);
      switch (kind) {
        // A value above 1 is the 보석 it paid; no card or 망작 pays as little as 1.
        case 'card':
          progress.cards[id] = record.at;
          if (record.value > 1) progress.cardGems[id] = record.value;
        case 'fail':
          progress.fails[id] = record.at;
          if (record.value > 1) progress.failGems[id] = record.value;
        case 'edition':
          progress.editions[id] = record.value;
        case 'season':
          progress.seasonGems[id] = record.value;
        case 'lesson' || 'stars' || 'section':
          progress.coursePaid[record.key] = record.value;
        case 'purchase':
          Map<String, Object?>? detail;
          try {
            final decoded = record.text == null ? null : jsonDecode(record.text!);
            if (decoded is Map) detail = decoded.cast<String, Object?>();
          } on Object {
            detail = null;
          }
          progress.purchases[id] = LabPurchase(price: (detail?['price'] as num?)?.toInt() ?? 0, count: record.value, date: record.at);
        case 'state':
          switch (id) {
            case 'type':
              progress.type = record.text;
              progress.diagnosed = record.at;
            case 'greeted':
              progress.greeted = record.value > 0;
            case 'legacyNoticed':
              progress.legacyNoticed = record.value > 0;
            case 'seenEdition':
              progress.seenEdition = record.text;
          }
      }
    }
    return progress;
  }

  List<LabRecord> get records => [
    for (final entry in cards.entries) LabRecord(key: 'card:${entry.key}', value: _paid(cardGems[entry.key]), at: entry.value),
    for (final entry in fails.entries) LabRecord(key: 'fail:${entry.key}', value: _paid(failGems[entry.key]), at: entry.value),
    // Editions have no date of their own here; the day in the id is enough to order them.
    for (final entry in editions.entries) LabRecord(key: 'edition:${entry.key}', value: entry.value, at: 0),
    for (final entry in seasonGems.entries) LabRecord(key: 'season:${entry.key}', value: entry.value, at: 0),
    for (final entry in coursePaid.entries) LabRecord(key: entry.key, value: entry.value, at: 0),
    for (final entry in purchases.entries) LabRecord(key: 'purchase:${entry.key}', value: entry.value.count, text: entry.value.detail, at: entry.value.date),
    if (type != null) LabRecord(key: 'state:type', value: 1, text: type, at: diagnosed ?? 0),
    if (greeted) const LabRecord(key: 'state:greeted', value: 1, at: 0),
    if (legacyNoticed) const LabRecord(key: 'state:legacyNoticed', value: 1, at: 0),
    if (seenEdition != null) LabRecord(key: 'state:seenEdition', value: 1, text: seenEdition, at: 0),
  ];

  static int _paid(int? gems) => gems == null || gems < 1 ? 1 : gems;

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
