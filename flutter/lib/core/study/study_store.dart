import 'dart:math';
import 'dart:typed_data';

import '../booru/booru_store.dart';
import '../support/sql_database.dart';
import '../support/swift_json.dart';
import 'study_awards.dart';
import 'study_models.dart';
import 'study_path.dart';

/// Tag study's rows in the image database: what has been learned, each day's answers and what servers said about tags.
class StudyStore {
  StudyStore(BooruStore booru) : database = booru.database;
  StudyStore.withDatabase(this.database);
  final SqlDatabase database;

  static void migrate(SqlDatabase db) {
    // Progress belongs to the tag, not to a server: the same tag means the same thing wherever it is used.
    db.execute('''
      CREATE TABLE study_progress (tag TEXT PRIMARY KEY NOT NULL, step INTEGER NOT NULL, due DOUBLE NOT NULL, correct INTEGER NOT NULL, wrong INTEGER NOT NULL, seen DOUBLE NOT NULL);
      CREATE TABLE study_days (day TEXT PRIMARY KEY NOT NULL, answered INTEGER NOT NULL, correct INTEGER NOT NULL);
      CREATE TABLE study_tags (address TEXT NOT NULL, name TEXT NOT NULL, payload BLOB NOT NULL, fetched DOUBLE NOT NULL, PRIMARY KEY(address, name));
      ''');
  }

  /// Learning mode's lessons and each day's experience.
  static void migrateGame(SqlDatabase db) {
    db.execute('''
      CREATE TABLE study_lessons (lesson TEXT PRIMARY KEY NOT NULL, stars INTEGER NOT NULL, runs INTEGER NOT NULL, finished DOUBLE NOT NULL);
      ALTER TABLE study_days ADD COLUMN xp INTEGER NOT NULL DEFAULT 0;
      ''');
  }

  /// Learning mode's badges and the counters kept for them.
  static void migrateAwards(SqlDatabase db) {
    db.execute('''
      CREATE TABLE study_awards (id TEXT PRIMARY KEY NOT NULL, earned DOUBLE NOT NULL, seen INTEGER NOT NULL DEFAULT 0);
      CREATE TABLE study_stats (name TEXT PRIMARY KEY NOT NULL, value INTEGER NOT NULL);
      ''');
  }

  /// Seconds since 1970, as both apps store and sync times.
  static double seconds(DateTime date) => date.microsecondsSinceEpoch / 1e6;
  static DateTime date(num seconds) => DateTime.fromMicrosecondsSinceEpoch((seconds * 1e6).round(), isUtc: true);

  static StudyProgress _progress(Map<String, Object?> row) => StudyProgress(
    tag: row['tag'] as String,
    step: row['step'] as int,
    due: date(row['due'] as num),
    correct: row['correct'] as int,
    wrong: row['wrong'] as int,
    seen: date(row['seen'] as num),
  );

  Map<String, StudyProgress> progress() => database.read((db) {
    final values = [for (final row in db.rows('SELECT * FROM study_progress')) _progress(row)];
    return {for (final value in values) value.tag: value};
  });

  List<StudyDay> days() => database.read(
    (db) => [
      for (final row in db.rows('SELECT * FROM study_days ORDER BY day DESC LIMIT 400'))
        StudyDay(day: row['day'] as String, answered: row['answered'] as int, correct: row['correct'] as int, xp: (row['xp'] as int?) ?? 0),
    ],
  );

  Map<String, StudyLessonRecord> lessons() => database.read(
    (db) => {
      for (final row in db.rows('SELECT lesson, stars, runs FROM study_lessons'))
        row['lesson'] as String: StudyLessonRecord(lesson: row['lesson'] as String, stars: row['stars'] as int, runs: row['runs'] as int),
    },
  );

  /// Adds experience to a day, and marks a lesson finished when one is named. The best stars are kept.
  void earn(int xp, {String? lesson, int stars = 0, DateTime? now, Duration? utcOffset}) => database.write((db) {
    final moment = now ?? DateTime.now();
    db.execute(
      '''
      INSERT INTO study_days (day, answered, correct, xp) VALUES (?, 0, 0, ?)
      ON CONFLICT(day) DO UPDATE SET xp = xp + excluded.xp
      ''',
      [StudyDay.key(moment, utcOffset: utcOffset), max(0, xp)],
    );
    if (lesson == null) return;
    db.execute(
      '''
      INSERT INTO study_lessons (lesson, stars, runs, finished) VALUES (?, ?, 1, ?)
      ON CONFLICT(lesson) DO UPDATE SET stars = MAX(stars, excluded.stars), runs = runs + 1, finished = excluded.finished
      ''',
      [lesson, min(3, max(1, stars)), seconds(moment)],
    );
  });

  Map<String, StudyAwardRecord> awards() => database.read(
    (db) => {
      for (final row in db.rows('SELECT id, earned, seen FROM study_awards'))
        row['id'] as String: StudyAwardRecord(id: row['id'] as String, earned: date(row['earned'] as num), seen: (row['seen'] as int) != 0),
    },
  );

  /// Records badges as earned. One already earned keeps its date.
  void grant(List<String> ids, {bool seen = false, DateTime? now}) {
    if (ids.isEmpty) return;
    final moment = now ?? DateTime.now();
    database.write((db) {
      for (final id in ids) {
        db.execute('INSERT OR IGNORE INTO study_awards (id, earned, seen) VALUES (?, ?, ?)', [id, seconds(moment), seen ? 1 : 0]);
      }
    });
  }

  void markSeen(List<String> ids) {
    if (ids.isEmpty) return;
    database.write((db) {
      for (final id in ids) {
        db.execute('UPDATE study_awards SET seen = 1 WHERE id = ?', [id]);
      }
    });
  }

  Map<String, int> stats() => database.read(
    (db) => {for (final row in db.rows('SELECT name, value FROM study_stats')) row['name'] as String: row['value'] as int},
  );

  /// Raises a counter to a value; a counter never goes down.
  void raise(String name, int to) => database.write((db) {
    db.execute(
      '''
      INSERT INTO study_stats (name, value) VALUES (?, ?)
      ON CONFLICT(name) DO UPDATE SET value = MAX(value, excluded.value)
      ''',
      [name, to],
    );
  });

  /// Records one answer and returns the tag's new progress.
  StudyProgress answer(String tag, {required bool right, DateTime? now, Duration? utcOffset}) => database.write((db) {
    final moment = now ?? DateTime.now();
    final row = db.row('SELECT * FROM study_progress WHERE tag = ?', [tag]);
    final current = row == null ? StudyProgress(tag: tag) : _progress(row);
    final next = current.answered(right, now: moment);
    write(next, db);
    db.execute(
      '''
      INSERT INTO study_days (day, answered, correct) VALUES (?, 1, ?)
      ON CONFLICT(day) DO UPDATE SET answered = answered + 1, correct = correct + excluded.correct
      ''',
      [StudyDay.key(moment, utcOffset: utcOffset), right ? 1 : 0],
    );
    return next;
  });

  static void write(StudyProgress value, SqlDatabase db) => db.execute(
    '''
    INSERT INTO study_progress (tag, step, due, correct, wrong, seen) VALUES (?, ?, ?, ?, ?, ?)
    ON CONFLICT(tag) DO UPDATE SET step = excluded.step, due = excluded.due, correct = excluded.correct, wrong = excluded.wrong, seen = excluded.seen
    ''',
    [value.tag, value.step, seconds(value.due), value.correct, value.wrong, seconds(value.seen)],
  );

  /// Forgets everything learned; what servers said about tags is kept.
  void reset() => database.write((db) {
    db.execute('DELETE FROM study_progress');
    db.execute('DELETE FROM study_days');
    db.execute('DELETE FROM study_lessons');
    db.execute('DELETE FROM study_awards');
    db.execute('DELETE FROM study_stats');
  });

  static StudyTagInfo? _info(Object? payload) {
    try {
      return StudyTagInfo.fromJson(decodeJsonObject(payload as Uint8List));
    } on Object {
      return null;
    }
  }

  StudyTagInfo? info(String name, {required String address}) => database.read((db) {
    final payload = db.value<Uint8List>('SELECT payload FROM study_tags WHERE address = ? AND name = ?', [address, name]);
    return payload == null ? null : _info(payload);
  });

  Map<String, int> counts({required String address}) => database.read((db) {
    final counts = <String, int>{};
    for (final payload in db.column<Uint8List>('SELECT payload FROM study_tags WHERE address = ?', [address])) {
      final info = _info(payload);
      final count = info?.count;
      if (info != null && count != null) counts[info.name] = count;
    }
    return counts;
  });

  void save(StudyTagInfo info, {required String address}) {
    final data = encodeSwiftJson(info.toJson());
    database.write((db) {
      db.execute('INSERT OR REPLACE INTO study_tags (address, name, payload, fetched) VALUES (?, ?, ?, ?)', [address, info.name, data, seconds(info.fetched)]);
      // The cache is a convenience; old answers leave so that it cannot grow without end.
      db.execute('DELETE FROM study_tags WHERE fetched < ?', [seconds(DateTime.now()) - StudyTagInfo.lifetime.inSeconds * 4]);
    });
  }

  /// What a removed server said about tags goes with it.
  static void forget(String address, SqlDatabase db) => db.execute('DELETE FROM study_tags WHERE address = ?', [address]);
}

extension BooruStoreStudy on BooruStore {
  StudyStore get studyStore => StudyStore(this);
}

/// The numbers the study screens show, worked out from what is stored.
class StudySummary {
  const StudySummary({this.total = 0, this.started = 0, this.learned = 0, this.due = 0, this.today = 0, this.todayCorrect = 0, this.streak = 0});

  factory StudySummary.of({
    required StudyCurriculum curriculum,
    required Map<String, StudyProgress> progress,
    required List<StudyDay> days,
    DateTime? now,
    Duration? utcOffset,
  }) {
    final moment = now ?? DateTime.now();
    var started = 0, learned = 0, due = 0;
    for (final value in progress.values) {
      if (!curriculum.contains(value.tag)) continue;
      if (!value.isNew) started += 1;
      if (value.isLearned) learned += 1;
      if (value.isDue(moment)) due += 1;
    }
    final answered = {
      for (final day in days)
        if (day.isStudied) day.day: day,
    };
    final todayKey = StudyDay.key(moment, utcOffset: utcOffset);
    // A streak still counts before today's first answer, so that it is not lost at midnight.
    var date = answered[todayKey] == null ? _previousDay(moment, utcOffset) : moment;
    var streak = 0;
    while (answered[StudyDay.key(date, utcOffset: utcOffset)] != null) {
      streak += 1;
      date = _previousDay(date, utcOffset);
    }
    return StudySummary(
      total: curriculum.count,
      started: started,
      learned: learned,
      due: due,
      today: answered[todayKey]?.answered ?? 0,
      todayCorrect: answered[todayKey]?.correct ?? 0,
      streak: streak,
    );
  }

  /// The calendar day before, so that a change of clocks cannot skip or repeat a day.
  static DateTime _previousDay(DateTime date, Duration? utcOffset) {
    if (utcOffset != null) return date.toUtc().subtract(const Duration(days: 1));
    final local = date.toLocal();
    return DateTime(local.year, local.month, local.day - 1, 12);
  }

  final int total;
  final int started;
  final int learned;
  final int due;
  final int today;
  final int todayCorrect;
  final int streak;

  static ({int learned, int started, int total}) unit(StudyUnit unit, {required Map<String, StudyProgress> progress}) {
    final tags = unit.tags;
    return (
      learned: tags.where((tag) => progress[tag.name]?.isLearned == true).length,
      started: tags.where((tag) => progress[tag.name]?.isNew == false).length,
      total: tags.length,
    );
  }

  @override
  bool operator ==(Object other) =>
      other is StudySummary &&
      other.total == total &&
      other.started == started &&
      other.learned == learned &&
      other.due == due &&
      other.today == today &&
      other.todayCorrect == todayCorrect &&
      other.streak == streak;
  @override
  int get hashCode => Object.hash(total, started, learned, due, today, todayCorrect, streak);
  @override
  String toString() => 'StudySummary(total $total, started $started, learned $learned, due $due, today $today/$todayCorrect, streak $streak)';
}
