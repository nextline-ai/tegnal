import 'dart:typed_data';

import '../booru/booru_models.dart';
import '../content/manga_urls.dart';
import '../support/sql_database.dart';
import '../support/swift_json.dart';
import 'taste_models.dart';

/// Analysis tables live beside each mode's library, so a save and its evidence commit together.
class TasteStore {
  TasteStore(this.database, this.mode);
  final SqlDatabase database;
  final TasteMode mode;

  static void migrate(SqlDatabase db) {
    db.execute('''
      CREATE TABLE taste_events (id TEXT PRIMARY KEY, epoch TEXT NOT NULL, generation TEXT NOT NULL, at DOUBLE NOT NULL, kind TEXT NOT NULL, work_key TEXT NOT NULL, payload BLOB NOT NULL, uploaded INTEGER NOT NULL DEFAULT 0);
      CREATE INDEX taste_events_period ON taste_events(epoch, at);
      CREATE INDEX taste_events_work ON taste_events(work_key, at);
      CREATE INDEX taste_events_pending ON taste_events(uploaded, at);
      CREATE TABLE taste_meta (key TEXT PRIMARY KEY, value BLOB NOT NULL);
      CREATE TABLE taste_reports (id TEXT PRIMARY KEY, payload BLOB NOT NULL, uploaded INTEGER NOT NULL DEFAULT 0);
      ''');
    final device = uuidString();
    put(
      TasteControl(author: device).toJson(),
      key: 'control',
      db: db,
    );
    put(device, key: 'device', db: db);
  }

  static Object? get(String key, SqlDatabase db) {
    final data = db.value<Uint8List>('SELECT value FROM taste_meta WHERE key = ?', [key]);
    return data == null ? null : decodeJsonValue(data);
  }

  static void put(Object? value, {required String key, required SqlDatabase db}) {
    // Idle sync persists its seen-file set repeatedly. Keep equal metadata
    // from dirtying SQLite and invalidating library snapshot caches.
    db.execute('INSERT INTO taste_meta (key, value) VALUES (?, ?) ON CONFLICT(key) DO UPDATE SET value = excluded.value WHERE value != excluded.value', [
      key,
      encodeJson(value),
    ]);
  }

  static TasteControl control(SqlDatabase db) {
    final value = get('control', db);
    return value == null ? TasteControl() : TasteControl.fromJson(jsonObject(value));
  }

  static void record(TasteEventKind kind, TasteItem item, SqlDatabase db, {DiscoveryContext? context, DateTime? at}) {
    final control = TasteStore.control(db);
    if (!control.enabled) return;
    if (kind == TasteEventKind.metadata) {
      final data = db.value<Uint8List>(
        "SELECT payload FROM taste_events WHERE work_key = ? AND kind IN ('save','seed','imported','metadata') ORDER BY at DESC, id DESC LIMIT 1",
        [item.key],
      );
      if (data != null) {
        try {
          if (TasteEvent.fromJson(decodeJsonObject(data)).item == item) return;
        } on SwiftJsonError {
          // An unreadable event is no evidence either way.
        }
      }
      if (!db.exists("SELECT EXISTS(SELECT 1 FROM taste_events WHERE work_key = ? AND kind IN ('save','seed','imported'))", [item.key])) return;
    }
    final event = TasteEvent(kind: kind, item: item, context: context, at: unixSeconds(at), epoch: control.epoch, generation: control.generation)
      ..device = get('device', db) as String? ?? '';
    if (kind == TasteEventKind.seed) {
      event
        ..id = 'seed-${tasteDigestOf(control.epoch + item.key)}'
        ..at = 0;
    }
    if (kind == TasteEventKind.taxonomy) {
      event.id = 'taxonomy-${tasteDigestOf(control.epoch + item.source + ([...item.metadata]..sort()).join('\n'))}';
    }
    if (kind == TasteEventKind.open) event.id = 'open-${tasteDigestOf(control.epoch + item.key + event.context.session)}';
    insert(event, db, uploaded: false);
  }

  /// Each viewing is its own open event, so existing peers count it as the open it is.
  static void recordDwell(TasteDwell dwell, TasteItem item, DiscoveryContext context, SqlDatabase db, {DateTime? at}) {
    final control = TasteStore.control(db);
    if (!control.enabled) return;
    final event = TasteEvent(
      id: 'dwell-${uuidString()}',
      kind: TasteEventKind.open,
      item: item,
      context: context,
      dwell: dwell,
      at: unixSeconds(at),
      epoch: control.epoch,
      generation: control.generation,
    )..device = get('device', db) as String? ?? '';
    insert(event, db, uploaded: false);
  }

  static void recordSignal(TasteSignal signal, TasteItem item, SqlDatabase db) {
    final control = TasteStore.control(db);
    if (!control.enabled) return;
    final event = TasteEvent(
      id: 'signal-${uuidString()}',
      kind: TasteEventKind.open,
      item: item,
      context: DiscoveryContext(origin: DiscoveryOrigin.external, session: 'signal'),
      signal: signal.name,
      epoch: control.epoch,
      generation: control.generation,
    )..device = get('device', db) as String? ?? '';
    insert(event, db, uploaded: false);
  }

  static void insert(TasteEvent event, SqlDatabase db, {required bool uploaded}) => db.execute(
    'INSERT OR IGNORE INTO taste_events VALUES (?, ?, ?, ?, ?, ?, ?, ?)',
    [event.id, event.epoch, event.generation, event.at, event.kind.name, event.item.key, encodeSwiftJson(event.toJson()), uploaded],
  );
}

/// Derived, device-local data. Only the tables are created here, so a library
/// moved between devices keeps the same schema; fingerprints are not computed yet.
abstract final class VisualFingerprintStore {
  static void migrate(SqlDatabase db) => db.execute('''
    CREATE TABLE visual_fingerprints (
        scope TEXT NOT NULL, item_id INTEGER NOT NULL, revision INTEGER NOT NULL,
        digest TEXT NOT NULL, payload BLOB NOT NULL,
        PRIMARY KEY(scope, item_id)
    );
    ''');

  static void installDeletionTrigger(SqlDatabase db) {
    if (db.tableExists('works')) {
      db.execute(
        "CREATE TRIGGER IF NOT EXISTS remove_visual_fingerprint AFTER DELETE ON works BEGIN DELETE FROM visual_fingerprints WHERE scope = 'comics' AND item_id = OLD.gallery_id; END;",
      );
    } else {
      db.execute(
        'CREATE TRIGGER IF NOT EXISTS remove_visual_fingerprint AFTER DELETE ON favorites BEGIN DELETE FROM visual_fingerprints WHERE scope = OLD.server_id AND item_id = OLD.post_id; END;',
      );
    }
  }
}

/// The instance side of [TasteStore]: one mode's analysis history and settings.
extension TasteStoreAccess on TasteStore {
  /// The keys of works the library currently holds, as analysis identifies them.
  Set<String> savedKeys() => database.read((db) {
    if (mode == TasteMode.comics) {
      return {for (final id in db.column<int>('SELECT gallery_id FROM works')) TasteItem.comic(id, source: MangaUrls.source).key};
    }
    final addresses = <String, String>{};
    for (final data in db.column<Uint8List>('SELECT payload FROM servers')) {
      final server = BooruServer.fromJson(decodeJsonObject(data));
      addresses.putIfAbsent(server.id, () => server.canonicalAddress);
    }
    return {
      for (final row in db.rows('SELECT server_id, post_id FROM favorites'))
        if (addresses[row['server_id'] as String] case final source?) '$source#${row['post_id']}',
    };
  });

  TasteControl control() => database.read(TasteStore.control);

  void setControl(TasteControl value, {bool remote = false}) => database.write((db) {
    final old = TasteStore.control(db);
    if (old.epoch != value.epoch) {
      db.execute('DELETE FROM taste_events');
      db.execute('DELETE FROM taste_reports');
      db.execute("DELETE FROM taste_meta WHERE key LIKE 'recap.%'");
      TasteStore.put(true, key: 'bootstrapped', db: db);
    } else if (remote && old.generation != value.generation) {
      // A peer that missed a pause must not upload activity collected under the old permission.
      db.execute('DELETE FROM taste_events WHERE uploaded = 0');
    }
    TasteStore.put(value.toJson(), key: 'control', db: db);
  });

  void record(TasteEventKind kind, TasteItem item, {DiscoveryContext? context}) => database.write((db) => TasteStore.record(kind, item, db, context: context));
  void recordSignal(TasteSignal signal, TasteItem item) => database.write((db) => TasteStore.recordSignal(signal, item, db));

  List<TasteEvent> events({TasteInterval? period}) => database.read((db) {
    final control = TasteStore.control(db);
    final arguments = <Object?>[
      control.epoch,
      if (period != null) ...[period.startSeconds, period.endSeconds],
    ];
    return db
        .column<Uint8List>('SELECT payload FROM taste_events WHERE epoch = ?${period == null ? '' : ' AND at >= ? AND at < ?'} ORDER BY at, id', arguments)
        .map((data) => TasteEvent.fromJson(decodeJsonObject(data)))
        .toList();
  });

  /// Every stored event in insertion order, for the analysis cache.
  List<TasteEvent> allEvents() => database.read(
    (db) => db.column<Uint8List>('SELECT payload FROM taste_events ORDER BY rowid').map((data) => TasteEvent.fromJson(decodeJsonObject(data))).toList(),
  );

  void bootstrap(List<TasteItem> items) => database.write((db) {
    if (!TasteStore.control(db).enabled || TasteStore.get('bootstrapped', db) == true) return;
    for (final item in items) {
      if (!db.exists("SELECT EXISTS(SELECT 1 FROM taste_events WHERE work_key = ? AND kind IN ('save','seed','imported','remove'))", [item.key])) {
        TasteStore.record(TasteEventKind.seed, item, db);
      }
    }
    TasteStore.put(true, key: 'bootstrapped', db: db);
  });

  List<TasteEvent> pending({int limit = 250}) => database.read(
    (db) => db
        .column<Uint8List>('SELECT payload FROM taste_events WHERE uploaded = 0 ORDER BY at DESC, id LIMIT ?', [limit])
        .map((data) => TasteEvent.fromJson(decodeJsonObject(data)))
        .toList(),
  );

  void acknowledge(List<String> ids) => database.write((db) {
    for (final id in ids) {
      db.execute('UPDATE taste_events SET uploaded = 1 WHERE id = ?', [id]);
    }
  });

  void merge(List<TasteEvent> events) => database.write((db) {
    final control = TasteStore.control(db);
    for (final event in events) {
      if (event.epoch == control.epoch) TasteStore.insert(event, db, uploaded: true);
    }
  });

  Object? metadata(String key) => database.read((db) => TasteStore.get(key, db));
  void setMetadata(Object? value, String key) => database.write((db) => TasteStore.put(value, key: key, db: db));
}
