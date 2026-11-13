import 'dart:convert';
import 'dart:typed_data';

import 'package:collection/collection.dart';

import '../../domain/models.dart';
import '../booru/booru_models.dart';
import '../booru/booru_store.dart';
import '../challenge/challenge_models.dart';
import '../content/recent_works.dart';
import '../storage/app_database.dart';
import '../storage/folder_rules.dart';
import '../support/preferences.dart';
import '../support/sql_database.dart';
import '../support/swift_json.dart';
import 'library_sync_record.dart';

/// Cheap change tokens avoid re-reading the entire library on idle sync polls.
/// `total_changes()` counts this connection's edits and `PRAGMA data_version` other
/// connections' commits, as the native cache reads them.
class LibrarySyncSnapshotCache {
  _Signature? _signature;
  Map<String, LibrarySyncRow> _rows = {};
  int snapshotCount = 0;

  Map<String, LibrarySyncRow> snapshot(LibrarySyncAdapter adapter) {
    final before = _signatureFor(adapter);
    if (_signature == before) return _rows;
    final next = adapter.snapshot();
    snapshotCount += 1;
    final after = _signatureFor(adapter);
    // A concurrent database edit must be read by the next pass.
    _signature = before == after ? after : null;
    _rows = next;
    return next;
  }

  void invalidate() {
    _signature = null;
    _rows = {};
  }

  _Signature _signatureFor(LibrarySyncAdapter adapter) {
    (Object, int, int) version(SqlDatabase db) => (db, db.value<int>('SELECT total_changes()') ?? 0, db.value<int>('PRAGMA data_version') ?? 0);
    final preferences = <String, String>{};
    for (final (mode, defaults, keys) in [
      ('manga', adapter.mangaDefaults, [...LibrarySyncAdapter.commonPreferences, RecentWorks.key]),
      ('booru', adapter.booruDefaults, [...LibrarySyncAdapter.booruPreferences, RecentImages.key]),
    ]) {
      for (final key in keys) {
        final value = defaults.object(key);
        if (value != null) preferences['$mode:$key'] = base64Encode(BinaryPropertyList.encode({'value': value}));
      }
    }
    return _Signature(version(adapter.manga.dbWriter), version(adapter.booru.database), preferences);
  }
}

class _Signature {
  _Signature(this.manga, this.booru, this.preferences);
  final (Object, int, int) manga;
  final (Object, int, int) booru;
  final Map<String, String> preferences;

  @override
  bool operator ==(Object other) =>
      other is _Signature &&
      identical(other.manga.$1, manga.$1) &&
      other.manga == manga &&
      identical(other.booru.$1, booru.$1) &&
      other.booru == booru &&
      const MapEquality<String, String>().equals(other.preferences, preferences);

  @override
  int get hashCode => Object.hash(manga, booru, const MapEquality<String, String>().hash(preferences));
}

class LibrarySyncError implements Exception {
  const LibrarySyncError();
}

/// Explicit allowlists keep caches, API keys, cookies, onboarding and device layout local.
class LibrarySyncAdapter {
  LibrarySyncAdapter({required this.manga, required this.booru, required this.mangaDefaults, required this.booruDefaults});

  final AppDatabase manga;
  final BooruStore booru;
  final Preferences mangaDefaults;
  final Preferences booruDefaults;

  static const commonPreferences = [
    'site_verified',
    'app.language',
    'app_theme',
    'booru.app_theme',
    'manga.defaultTags',
    'manga.defaultExcludedTags',
    'manga.artistLanguage',
    'manga.tagLanguage',
    'search.retentionDays',
    'search.rememberHistory',
    'reader.translationLanguage',
    LibrarySavePreferences.defaultFolderKey,
    LibrarySavePreferences.rulesEnabledKey,
    RecentWorks.limitKey,
  ];
  static const booruPreferences = ['search.retentionDays', 'reader.translationLanguage', 'booru.rememberHistory', 'booru.showNotes', RecentImages.limitKey];

  static const columns = <String, List<String>>{
    'manga.library_order': ['key', 'value'],
    'manga.folders': ['sync_id', 'name', 'description', 'color', 'sort_order', 'created_at', 'source_group_id'],
    'manga.works': [
      'gallery_id',
      'title',
      'artists',
      'language',
      'type',
      'series',
      'groups',
      'tags',
      'note',
      'bookmarked_at',
      'published_at',
      'metadata_source',
      'catalog_matched',
      'thumb_page',
      'site',
    ],
    'manga.folder_works': ['folder_id', 'work_id', 'added_at'],
    'manga.artists': ['name', 'kind', 'note', 'bookmarked_at'],
    'manga.search_history': ['query', 'used_at'],
    'manga.saved_searches': ['query'],
    'booru.challenges': ['id', 'payload'],
    'booru.servers': ['id', 'payload', 'position'],
    'booru.folders': ['id', 'name', 'color', 'position'],
    'booru.favorites': ['server_id', 'post_id', 'payload', 'saved_at', 'folder_id'],
    'booru.history': ['server_id', 'query', 'used_at'],
    'booru.saved_tags': ['server_id', 'name', 'kind'],
    'booru.settings': ['key', 'value'],
  };

  /// Columns a peer that does not know the value yet sends empty: they fill in, never clear.
  static const keepsKnownValue = {'site'};

  /// Also gives identities to legacy imports and folders made outside the app.
  void _assignFolderIdentities() {
    manga.dbWriter.write((db) {
      for (final row in db.rows('SELECT id, name FROM folders WHERE sync_id IS NULL')) {
        db.execute('UPDATE folders SET sync_id = ? WHERE id = ?', [row['name'] == '미분류' ? 'unsorted' : uuidString(), row['id']]);
      }
      LibrarySavePreferences.defaultFolderIdentity(db, mangaDefaults);
    });
  }

  /// Image settings stay local unless they describe the library itself.
  static bool _travelsUnchanged(String? key) => key == 'folder_order' || (key?.startsWith(FolderRule.keyPrefix) ?? false);

  static Uint8List _encode(JsonObject value) => encodeJson(value, escapingSlashes: false);

  Map<String, LibrarySyncRow> snapshot() {
    _assignFolderIdentities();
    final rows = manga.dbWriter.read((db) {
      final result = <LibrarySyncRow>[];
      for (final MapEntry(key: table, value: names) in columns.entries) {
        if (!table.startsWith('manga.')) continue;
        final local = table.substring(6);
        final sql = local == 'folder_works'
            ? 'SELECT f.sync_id AS folder_id, w.gallery_id AS work_id, fw.added_at FROM folder_works fw JOIN folders f ON f.id = fw.folder_id JOIN works w ON w.id = fw.work_id'
            : 'SELECT ${names.join(',')} FROM $local';
        for (final row in db.rows(sql)) {
          result.add(LibrarySyncRow(table: table, values: {for (final name in names) name: SyncValue.fromDatabase(row[name])}));
        }
      }
      return result;
    });
    rows.addAll(
      booru.database.read((db) {
        final servers = [for (final payload in db.column<Uint8List>('SELECT payload FROM servers')) BooruServer.fromJson(decodeJsonObject(payload))];
        final addresses = {for (final server in servers) server.id: server.canonicalAddress};
        final result = <LibrarySyncRow>[];
        for (final MapEntry(key: table, value: names) in columns.entries) {
          if (!table.startsWith('booru.')) continue;
          final local = table.substring(6);
          for (final row in db.rows('SELECT ${names.join(',')} FROM $local')) {
            final values = {for (final name in names) name: SyncValue.fromDatabase(row[name])};
            if (local == 'servers') {
              final raw = values['payload']?.data;
              if (raw != null) {
                final server = BooruServer.fromJson(decodeJsonObject(raw));
                server.id = server.canonicalAddress;
                values['id'] = SyncValue.text(server.id);
                values['payload'] = SyncValue.blob(_encode(server.toJson()));
              }
            }
            final serverID = values['server_id']?.string;
            final address = serverID == null ? null : addresses[serverID];
            if (address != null) {
              values['server_id'] = SyncValue.text(address);
              final raw = values['payload']?.data;
              if (raw != null) {
                final post = BooruPost.fromJson(decodeJsonObject(raw)).onServer(address).cloudMetadata;
                values['payload'] = SyncValue.blob(_encode(post.toJson()));
              }
            }
            if (local == 'settings' && !_travelsUnchanged(values['key']?.string)) {
              final key = values['key']?.string;
              if (key == null || !key.startsWith('blacklist.')) continue;
              final mapped = addresses[key.substring(10)];
              if (mapped == null) continue;
              values['key'] = SyncValue.text('blacklist.$mapped');
            }
            result.add(LibrarySyncRow(table: table, values: values));
          }
        }
        // One row per recently opened image, so opens on two devices merge. A server that
        // is no longer in the list cannot place its image on another device.
        for (final entry in RecentImage.stored(booruDefaults)) {
          final address = addresses[entry.post.serverID];
          if (address == null) continue;
          final post = entry.post.onServer(address).cloudMetadata;
          result.add(
            LibrarySyncRow(
              table: 'recent.images',
              values: {
                'server_id': SyncValue.text(address),
                'post_id': SyncValue.integer(post.postID),
                'payload': SyncValue.blob(_encode(RecentImage(post: post, openedAt: entry.openedAt).toJson())),
              },
            ),
          );
        }
        return result;
      }),
    );
    for (final entry in RecentWork.stored(mangaDefaults)) {
      rows.add(LibrarySyncRow(table: 'recent.works', values: {'id': SyncValue.integer(entry.id), 'payload': SyncValue.blob(_encode(entry.toJson()))}));
    }
    for (final (mode, defaults, keys) in [('manga', mangaDefaults, commonPreferences), ('booru', booruDefaults, booruPreferences)]) {
      for (final key in keys) {
        final value = defaults.object(key);
        if (value == null) continue;
        rows.add(
          LibrarySyncRow(
            table: 'preferences.$mode',
            values: {
              'key': SyncValue.text(key),
              'value': SyncValue.blob(BinaryPropertyList.encode({'value': value})),
            },
          ),
        );
      }
    }
    final result = <String, LibrarySyncRow>{};
    for (final row in rows) {
      result.putIfAbsent(row.key, () => row);
    }
    return result;
  }

  /// Normalizes old peer records as well as new snapshots before they are uploaded again.
  static Map<String, LibrarySyncChange> mediaFreeChanges(Map<String, LibrarySyncChange> changes) => changes.map((key, change) {
    if (change.row.table == 'manga.folders') {
      final row = LibrarySyncRow(table: change.row.table, values: MangaImportMetadata.normalized(change.row.values));
      return MapEntry(key, LibrarySyncChange(row: row, timestamp: change.timestamp, device: change.device, deleted: change.deleted));
    }
    final data = change.row.values['payload']?.data;
    if (change.deleted || !const {'booru.favorites', 'recent.images'}.contains(change.row.table) || data == null) return MapEntry(key, change);
    final JsonObject cleaned;
    if (change.row.table == 'recent.images') {
      final entry = RecentImage.fromJson(decodeJsonObject(data));
      cleaned = RecentImage(post: entry.post.cloudMetadata, openedAt: entry.openedAt).toJson();
    } else {
      cleaned = BooruPost.fromJson(decodeJsonObject(data)).cloudMetadata.toJson();
    }
    final row = change.row.copy()..values['payload'] = SyncValue.blob(_encode(cleaned));
    return MapEntry(key, LibrarySyncChange(row: row, timestamp: change.timestamp, device: change.device, deleted: change.deleted));
  });

  void apply(Map<String, LibrarySyncChange> changes) {
    _assignFolderIdentities();
    final values = changes.values.toList();
    manga.dbWriter.write((db) {
      // Remove dependent links before parents; never replace a whole database.
      for (final table in ['folder_works', 'artists', 'works', 'folders', 'search_history', 'saved_searches', 'library_order']) {
        for (final change in values) {
          if (!change.deleted || change.row.table != 'manga.$table') continue;
          final row = change.row.copy();
          if (table == 'folders' &&
              row.values['sync_id']?.string == 'unsorted' &&
              db.exists("SELECT EXISTS(SELECT 1 FROM folder_works JOIN folders ON folders.id = folder_works.folder_id WHERE folders.sync_id = 'unsorted')")) {
            continue;
          }
          if (table == 'folder_works') {
            final folder = _localFolder(row.values['folder_id'], db), work = _localWork(row.values['work_id'], db);
            if (folder == null || work == null) continue;
            row.values['folder_id'] = SyncValue.integer(folder);
            row.values['work_id'] = SyncValue.integer(work);
          }
          _delete(row, db);
        }
      }
      final sorted = [...values]..sort((a, b) => a.row.key.compareTo(b.row.key));
      for (final table in ['folders', 'works', 'artists', 'folder_works', 'search_history', 'saved_searches', 'library_order']) {
        for (final change in sorted) {
          if (change.deleted || change.row.table != 'manga.$table') continue;
          final row = change.row.copy();
          if (table == 'folders') {
            final uid = row.values['sync_id']?.string, name = row.values['name']?.string;
            if (uid != null && name != null) {
              final conflict = db.value<String>('SELECT sync_id FROM folders WHERE name = ?', [name]);
              if (conflict != null && conflict != uid) row.values['name'] = SyncValue.text('$name (${uid.substring(0, uid.length < 8 ? uid.length : 8)})');
            }
          }
          if (table == 'folder_works') {
            final folder = _localFolder(row.values['folder_id'], db), work = _localWork(row.values['work_id'], db);
            if (folder == null || work == null) continue;
            row.values['folder_id'] = SyncValue.integer(folder);
            row.values['work_id'] = SyncValue.integer(work);
          }
          _upsert(row, db);
        }
      }
      final orderData = db.value<Uint8List>("SELECT value FROM library_order WHERE key = 'folders'");
      final order = _decodeStrings(orderData);
      if (order != null) {
        final others = db.column<String>('SELECT sync_id FROM folders ORDER BY sort_order, id').where((uid) => !order.contains(uid));
        for (final (position, uid) in [...order, ...others].indexed) {
          db.execute('UPDATE folders SET sort_order = ? WHERE sync_id = ?', [position, uid]);
        }
      }
      // Concurrent folder deletion cannot orphan an independently saved work.
      if (db.exists('SELECT EXISTS(SELECT 1 FROM works WHERE id NOT IN (SELECT work_id FROM folder_works))')) {
        final unfiled = AppDatabase.unfiledFolder(db).id!;
        db.execute('INSERT OR IGNORE INTO folder_works SELECT ?, id, bookmarked_at FROM works WHERE id NOT IN (SELECT work_id FROM folder_works)', [unfiled]);
      }
    });
    booru.database.write((db) {
      final servers = [for (final payload in db.column<Uint8List>('SELECT payload FROM servers')) BooruServer.fromJson(decodeJsonObject(payload))];
      final mapping = <String, String>{};
      for (final server in servers) {
        mapping.putIfAbsent(server.canonicalAddress, () => server.id);
      }
      for (final change in values) {
        if (change.row.table != 'booru.servers') continue;
        final address = change.row.values['id']?.string;
        if (address == null) continue;
        if (change.deleted) {
          final id = mapping[address];
          if (id != null) {
            for (final table in ['favorites', 'history', 'saved_tags']) {
              db.execute('DELETE FROM $table WHERE server_id = ?', [id]);
            }
            db.execute('DELETE FROM servers WHERE id = ?', [id]);
            mapping.remove(address);
          }
        } else {
          final data = change.row.values['payload']?.data;
          if (data == null) continue;
          final server = BooruServer.fromJson(decodeJsonObject(data));
          BooruServer.validatedURL(server.baseURL);
          if (server.canonicalAddress != address) throw const BooruError(BooruErrorKind.invalidServer);
          server.id = mapping[address] ?? uuidString();
          mapping[address] = server.id;
          final row = change.row.copy()
            ..values['id'] = SyncValue.text(server.id)
            ..values['payload'] = SyncValue.blob(_encode(server.toJson()));
          _upsert(row, db);
        }
      }
      for (final table in ['folders', 'favorites', 'history', 'saved_tags', 'settings', 'challenges']) {
        for (final change in values) {
          if (change.row.table != 'booru.$table') continue;
          final row = change.row.copy();
          if (table == 'folders' && row.values['id']?.string == 'unsorted' && change.deleted) continue;
          final address = row.values['server_id']?.string;
          if (address != null) {
            final id = mapping[address];
            if (id == null) continue;
            row.values['server_id'] = SyncValue.text(id);
            final data = row.values['payload']?.data;
            if (data != null) row.values['payload'] = SyncValue.blob(_encode(BooruPost.fromJson(decodeJsonObject(data)).onServer(id).toJson()));
          }
          if (table == 'settings' && !_travelsUnchanged(row.values['key']?.string)) {
            final key = row.values['key']?.string;
            if (key == null || !key.startsWith('blacklist.')) continue;
            final id = mapping[key.substring(10)];
            if (id == null) continue;
            row.values['key'] = SyncValue.text('blacklist.$id');
          }
          if (table == 'challenges' && !change.deleted) {
            final data = row.values['payload']?.data;
            if (data == null || data.length > ChallengeBackup.maximumBytes) throw const ChallengeError.unsupported();
            final game = ChallengeDefinition.fromJson(decodeJsonObject(data));
            game.validate();
            if (game.id != row.values['id']?.string) throw const ChallengeError.invalid('Challenges');
          }
          if (change.deleted) {
            final id = row.values['id']?.string;
            if (table == 'challenges' && id != null) db.execute('DELETE FROM challenge_sessions WHERE id = ?', [id]);
            if (table == 'folders' && id != null && db.exists('SELECT EXISTS(SELECT 1 FROM favorites WHERE folder_id = ?)', [id])) {
              BooruStore.ensureUnsorted(db);
              db.execute("UPDATE favorites SET folder_id = 'unsorted' WHERE folder_id = ?", [id]);
            }
            _delete(row, db);
          } else {
            final folder = row.values['folder_id']?.string;
            if (table == 'favorites' && folder != null && db.value<String>('SELECT id FROM folders WHERE id = ?', [folder]) == null) {
              BooruStore.ensureUnsorted(db);
              row.values['folder_id'] = const SyncValue.text('unsorted');
            }
            _upsert(row, db);
          }
        }
      }
      // Apply default-folder deletion after favorite changes; concurrent saves take precedence.
      if (values.any((change) => change.deleted && change.row.table == 'booru.folders' && change.row.values['id']?.string == 'unsorted')) {
        db.execute("DELETE FROM folders WHERE id = 'unsorted' AND NOT EXISTS(SELECT 1 FROM favorites WHERE folder_id = 'unsorted')");
      }
      final text = db.value<String>("SELECT value FROM settings WHERE key = 'folder_order'");
      final order = text == null ? null : _decodeStrings(utf8.encode(text));
      if (order != null) {
        final others = db.column<String>('SELECT id FROM folders ORDER BY position, name').where((id) => !order.contains(id));
        for (final (position, id) in [...order, ...others].indexed) {
          db.execute('UPDATE folders SET position = ? WHERE id = ?', [position, id]);
        }
      }
    });
    for (final change in values) {
      if (!change.row.table.startsWith('preferences.')) continue;
      final isBooru = change.row.table == 'preferences.booru';
      final key = change.row.values['key']?.string;
      if (key == null || !(isBooru ? booruPreferences : commonPreferences).contains(key)) continue;
      final defaults = isBooru ? booruDefaults : mangaDefaults;
      if (change.deleted) {
        defaults.remove(key);
        continue;
      }
      final data = change.row.values['value']?.data;
      if (data == null) continue;
      final plist = BinaryPropertyList.decode(data);
      if (plist is! Map) continue;
      final value = plist['value'];
      defaults.set(key, value is List ? value.whereType<String>().toList() : value);
    }
    _applyRecents(values);
  }

  /// Recent lists live in each mode's settings, not a database. Rows merge one entry at a
  /// time; the synced count then keeps the newest ones, as on the device that opened them.
  void _applyRecents(List<LibrarySyncChange> values) {
    final works = values.where((change) => change.row.table == 'recent.works').toList();
    if (works.isNotEmpty) {
      final entries = {for (final entry in RecentWork.stored(mangaDefaults)) entry.id: entry};
      for (final change in works) {
        final id = change.row.values['id']?.integer;
        if (id == null) continue;
        if (change.deleted) {
          entries.remove(id);
          continue;
        }
        final data = change.row.values['payload']?.data;
        if (data == null) continue;
        try {
          final entry = RecentWork.fromJson(decodeJsonObject(data));
          if (entry.id == id) entries[id] = entry;
        } on Object {
          continue;
        }
      }
      _storeRecentWorks(RecentWork.merged(entries.values, RecentLimit.stored(mangaDefaults, RecentWorks.limitKey)));
    }
    final images = values.where((change) => change.row.table == 'recent.images').toList();
    if (images.isNotEmpty) {
      final mapping = <String, String>{};
      booru.database.read((db) {
        for (final payload in db.column<Uint8List>('SELECT payload FROM servers ORDER BY position')) {
          final server = BooruServer.fromJson(decodeJsonObject(payload));
          mapping.putIfAbsent(server.canonicalAddress, () => server.id);
        }
      });
      final entries = {for (final entry in RecentImage.stored(booruDefaults)) entry.id: entry};
      for (final change in images) {
        final address = change.row.values['server_id']?.string, postID = change.row.values['post_id']?.integer;
        final server = address == null ? null : mapping[address];
        if (server == null || postID == null) continue;
        final id = '$server:$postID';
        if (change.deleted) {
          entries.remove(id);
          continue;
        }
        final data = change.row.values['payload']?.data;
        if (data == null) continue;
        try {
          final entry = RecentImage.fromJson(decodeJsonObject(data));
          if (entry.post.postID == postID) entries[id] = RecentImage(post: entry.post.onServer(server), openedAt: entry.openedAt);
        } on Object {
          continue;
        }
      }
      _storeRecentImages(RecentImage.merged(entries.values, RecentLimit.stored(booruDefaults, RecentImages.limitKey)));
    }
  }

  void _storeRecentWorks(List<RecentWork> entries) {
    String encoded(List<RecentWork> list) => jsonEncode([for (final entry in list) entry.toJson()]);
    if (encoded(RecentWork.stored(mangaDefaults)) != encoded(entries)) RecentWork.store(mangaDefaults, entries);
  }

  void _storeRecentImages(List<RecentImage> entries) {
    String encoded(List<RecentImage> list) => jsonEncode([for (final entry in list) entry.toJson()]);
    if (encoded(RecentImage.stored(booruDefaults)) != encoded(entries)) RecentImage.store(booruDefaults, entries);
  }

  static List<String>? _decodeStrings(List<int>? data) {
    if (data == null) return null;
    try {
      final value = decodeJsonValue(data);
      return value is List && value.every((item) => item is String) ? value.cast<String>() : null;
    } on Object {
      return null;
    }
  }

  int? _localFolder(SyncValue? value, SqlDatabase db) {
    final uid = value?.string;
    return uid == null ? null : db.value<int>('SELECT id FROM folders WHERE sync_id = ?', [uid]);
  }

  int? _localWork(SyncValue? value, SqlDatabase db) {
    final id = value?.integer;
    return id == null ? null : db.value<int>('SELECT id FROM works WHERE gallery_id = ?', [id]);
  }

  static void _upsert(LibrarySyncRow incoming, SqlDatabase db) {
    final row = incoming.table == 'manga.folders' ? LibrarySyncRow(table: incoming.table, values: MangaImportMetadata.normalized(incoming.values)) : incoming;
    final allowed = columns[row.table], keys = LibrarySyncRow.keys[row.table];
    if (allowed == null || keys == null || !keys.every(row.values.containsKey)) {
      throw const BooruError(BooruErrorKind.invalidResponse);
    }
    // Columns this version does not know yet, sent by a newer one, are left out rather than
    // turning the whole row away; the record itself still carries them on to other devices.
    final fields = allowed.where(row.values.containsKey).toList();
    final updates = fields
        .where((field) => !keys.contains(field))
        .map((field) => keepsKnownValue.contains(field) ? '$field = COALESCE(excluded.$field, $field)' : '$field = excluded.$field')
        .join(',');
    final local = row.table.split('.')[1];
    final sql =
        'INSERT INTO $local (${fields.join(',')}) VALUES (${fields.map((_) => '?').join(',')}) ON CONFLICT(${keys.join(',')}) DO ${updates.isEmpty ? 'NOTHING' : 'UPDATE SET $updates'}';
    db.execute(sql, [for (final field in fields) row.values[field]!.databaseValue]);
  }

  static void _delete(LibrarySyncRow row, SqlDatabase db) {
    final keys = LibrarySyncRow.keys[row.table];
    if (keys == null || columns[row.table] == null) throw const BooruError(BooruErrorKind.invalidResponse);
    db.execute('DELETE FROM ${row.table.split('.')[1]} WHERE ${keys.map((key) => '$key = ?').join(' AND ')}', [
      for (final key in keys) row.values[key]?.databaseValue,
    ]);
  }
}
