import 'dart:typed_data';

import '../support/sql_database.dart';
import '../support/swift_json.dart';
import 'taste_models.dart';

/// Analysis tables live beside each mode's library, so a save and its evidence commit together.
/// Only the recording path is ported so far; reading and sync arrive with the taste screens.
abstract final class TasteStore {
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
