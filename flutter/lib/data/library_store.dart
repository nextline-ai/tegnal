import 'dart:convert';

import 'package:sqlite3/sqlite3.dart';

import '../core/content.dart';
import '../core/library.dart';

/// One transactional database for both libraries. Never replaces a corrupt DB
/// with an empty library; opening errors are surfaced to the app instead.
class LibraryStore {
  LibraryStore(this.database) {
    database.execute('PRAGMA foreign_keys = ON');
    final version = database.userVersion;
    if (version > 1) {
      throw StateError('This library requires a newer version of TEGNAL.');
    }
    if (version == 0) {
      transaction(() {
        database.execute('''
          CREATE TABLE settings (key TEXT PRIMARY KEY, value TEXT NOT NULL);
          CREATE TABLE sources (id TEXT PRIMARY KEY, mode TEXT NOT NULL, payload TEXT NOT NULL);
          CREATE TABLE folders (id TEXT PRIMARY KEY, mode TEXT NOT NULL, name TEXT NOT NULL, color INTEGER NOT NULL, position INTEGER NOT NULL);
          CREATE TABLE items (key TEXT PRIMARY KEY, mode TEXT NOT NULL, payload TEXT NOT NULL, saved_at TEXT NOT NULL, note TEXT NOT NULL DEFAULT '');
          CREATE TABLE memberships (item_key TEXT NOT NULL REFERENCES items(key) ON DELETE CASCADE, folder_id TEXT NOT NULL REFERENCES folders(id) ON DELETE CASCADE, PRIMARY KEY(item_key,folder_id));
          CREATE TABLE progress (item_key TEXT PRIMARY KEY, page INTEGER NOT NULL, updated_at TEXT NOT NULL);
          CREATE TABLE history (mode TEXT NOT NULL, source_id TEXT NOT NULL, query TEXT NOT NULL, used_at TEXT NOT NULL, PRIMARY KEY(mode,source_id,query));
          CREATE TABLE artists (key TEXT PRIMARY KEY, mode TEXT NOT NULL, payload TEXT NOT NULL);
          CREATE TABLE downloads (item_key TEXT PRIMARY KEY, payload TEXT NOT NULL);
          CREATE TABLE portable (key TEXT PRIMARY KEY, payload TEXT NOT NULL);
          CREATE INDEX items_mode ON items(mode,saved_at);
          CREATE INDEX folders_mode ON folders(mode,position);
        ''');
        database.userVersion = 1;
      });
    }
  }
  factory LibraryStore.memory() => LibraryStore(sqlite3.openInMemory());
  final Database database;
  int _transactionDepth = 0;

  T transaction<T>(T Function() body) {
    if (_transactionDepth > 0) {
      return body();
    }
    database.execute('BEGIN IMMEDIATE');
    _transactionDepth++;
    try {
      final result = body();
      database.execute('COMMIT');
      return result;
    } catch (_) {
      database.execute('ROLLBACK');
      rethrow;
    } finally {
      _transactionDepth--;
    }
  }

  dynamic setting(String key, [dynamic fallback]) {
    final rows = database.select('SELECT value FROM settings WHERE key = ?', [
      key,
    ]);
    return rows.isEmpty ? fallback : jsonDecode(rows.first['value'] as String);
  }

  void setSetting(String key, dynamic value) => database.execute(
    'INSERT INTO settings VALUES (?,?) ON CONFLICT(key) DO UPDATE SET value=excluded.value',
    [key, jsonEncode(value)],
  );

  List<SourceConfig> sources([AppMode? mode]) => database
      .select(
        'SELECT payload FROM sources${mode == null ? '' : ' WHERE mode=?'} ORDER BY rowid',
        mode == null ? [] : [mode.name],
      )
      .map((r) => SourceConfig.fromJson(_json(r['payload'])))
      .toList();
  void saveSource(SourceConfig source) {
    SourceConfig.validateUrl(source.baseUrl.toString());
    database.execute(
      'INSERT INTO sources VALUES (?,?,?) ON CONFLICT(id) DO UPDATE SET mode=excluded.mode,payload=excluded.payload',
      [source.id, source.mode.name, jsonEncode(source.toJson())],
    );
  }

  void removeSource(String id) =>
      database.execute('DELETE FROM sources WHERE id=?', [id]);

  List<LibraryFolder> folders(AppMode mode) => database
      .select('SELECT * FROM folders WHERE mode=? ORDER BY position,name', [
        mode.name,
      ])
      .map((r) => LibraryFolder.fromJson(r))
      .toList();
  void saveFolder(LibraryFolder folder) {
    if (folder.name.trim().isEmpty ||
        folder.color < 0 ||
        folder.color > 0xFFFFFFFF) {
      throw const FormatException('A folder needs a name and valid color.');
    }
    final current = database.select('SELECT mode FROM folders WHERE id=?', [
      folder.id,
    ]);
    if (current.isNotEmpty && current.first['mode'] != folder.mode.name) {
      throw const FormatException('Folder belongs to another library.');
    }
    database.execute(
      'INSERT INTO folders VALUES (?,?,?,?,?) ON CONFLICT(id) DO UPDATE SET name=excluded.name,color=excluded.color,position=excluded.position',
      [
        folder.id,
        folder.mode.name,
        folder.name.trim(),
        folder.color,
        folder.position,
      ],
    );
  }

  void deleteFolder(String id) =>
      database.execute('DELETE FROM folders WHERE id=?', [id]);

  List<SavedItem> items(AppMode mode, {String? folderId, String query = ''}) {
    final rows = database.select(
      'SELECT * FROM items WHERE mode=? ORDER BY saved_at DESC',
      [mode.name],
    );
    final memberships = <String, List<String>>{};
    for (final r in database.select(
      'SELECT item_key,folder_id FROM memberships',
    )) {
      memberships
          .putIfAbsent(r['item_key'] as String, () => [])
          .add(r['folder_id'] as String);
    }
    final needle = query.trim().toLowerCase();
    return rows
        .map(
          (r) => SavedItem(
            item: ContentItem.fromJson(_json(r['payload'])),
            savedAt: DateTime.parse(r['saved_at'] as String),
            note: r['note'] as String,
            folderIds: memberships[r['key']] ?? [],
          ),
        )
        .where(
          (s) =>
              (folderId == null ||
                  (folderId == 'unsorted'
                      ? s.folderIds.isEmpty
                      : s.folderIds.contains(folderId))) &&
              (needle.isEmpty ||
                  '${s.item.title} ${s.item.id} ${s.item.tags.join(' ')} ${s.item.artists.join(' ')} ${s.note}'
                      .toLowerCase()
                      .contains(needle)),
        )
        .toList();
  }

  SavedItem? saved(String key) {
    final rows = database.select('SELECT * FROM items WHERE key=?', [key]);
    if (rows.isEmpty) {
      return null;
    }
    final r = rows.first;
    return SavedItem(
      item: ContentItem.fromJson(_json(r['payload'])),
      savedAt: DateTime.parse(r['saved_at'] as String),
      note: r['note'] as String,
      folderIds: database
          .select('SELECT folder_id FROM memberships WHERE item_key=?', [key])
          .map((r) => r['folder_id'] as String)
          .toList(),
    );
  }

  bool isSaved(String key) =>
      database.select('SELECT 1 FROM items WHERE key=?', [key]).isNotEmpty;
  void saveItem(
    ContentItem item, {
    List<String>? folderIds,
    String? note,
    DateTime? savedAt,
  }) {
    if (item.id <= 0) {
      throw const FormatException('Invalid content ID.');
    }
    transaction(() {
      final previous = saved(item.key)?.item;
      final payload = item.toJson();
      if (previous != null) {
        payload['metadata'] = {...previous.metadata, ...item.metadata};
        // Empty response fields do not erase portable metadata from imports.
        if (item.artists.isEmpty) {
          payload['artists'] = previous.artists;
        }
        if (item.tags.isEmpty) {
          payload['tags'] = previous.tags;
        }
      }
      if (item.mode == AppMode.booru &&
          folderIds != null &&
          folderIds.where((id) => id != 'unsorted').toSet().length > 1) {
        throw const FormatException(
          'An image belongs to one folder at a time.',
        );
      }
      database.execute(
        'INSERT INTO items VALUES (?,?,?,?,?) ON CONFLICT(key) DO UPDATE SET payload=excluded.payload',
        [
          item.key,
          item.mode.name,
          jsonEncode(payload),
          (savedAt ?? DateTime.now().toUtc()).toIso8601String(),
          note ?? '',
        ],
      );
      if (note != null) {
        database.execute('UPDATE items SET note=? WHERE key=?', [
          note,
          item.key,
        ]);
      }
      if (savedAt != null) {
        database.execute('UPDATE items SET saved_at=? WHERE key=?', [
          savedAt.toUtc().toIso8601String(),
          item.key,
        ]);
      }
      if (folderIds != null) {
        database.execute('DELETE FROM memberships WHERE item_key=?', [
          item.key,
        ]);
        for (final id in folderIds.toSet()) {
          if (id == 'unsorted') {
            continue;
          }
          final folder = database.select(
            'SELECT mode FROM folders WHERE id=?',
            [id],
          );
          if (folder.isEmpty || folder.first['mode'] != item.mode.name) {
            throw const FormatException('Unknown folder.');
          }
          database.execute('INSERT INTO memberships VALUES (?,?)', [
            item.key,
            id,
          ]);
        }
      }
    });
  }

  void removeItem(String key) =>
      database.execute('DELETE FROM items WHERE key=?', [key]);
  int progress(String key) {
    final rows = database.select('SELECT page FROM progress WHERE item_key=?', [
      key,
    ]);
    return rows.isEmpty ? 0 : rows.first['page'] as int;
  }

  void setProgress(String key, int page) {
    if (page < 0) {
      return;
    }
    database.execute(
      'INSERT INTO progress VALUES (?,?,?) ON CONFLICT(item_key) DO UPDATE SET page=excluded.page,updated_at=excluded.updated_at',
      [key, page, DateTime.now().toUtc().toIso8601String()],
    );
  }

  List<SearchEntry> history(AppMode mode, {int? limit = 100}) => database
      .select(
        'SELECT * FROM history WHERE mode=? ORDER BY used_at DESC${limit == null ? '' : ' LIMIT ?'}',
        [mode.name, ?limit],
      )
      .map(
        (r) => SearchEntry(
          mode,
          r['source_id'] as String,
          r['query'] as String,
          DateTime.parse(r['used_at'] as String),
        ),
      )
      .toList();
  void recordSearch(
    AppMode mode,
    String sourceId,
    String query, {
    DateTime? usedAt,
  }) {
    if (query.trim().isEmpty) {
      return;
    }
    database.execute(
      'INSERT INTO history VALUES (?,?,?,?) ON CONFLICT(mode,source_id,query) DO UPDATE SET used_at=MAX(used_at,excluded.used_at)',
      [
        mode.name,
        sourceId,
        query.trim(),
        (usedAt ?? DateTime.now().toUtc()).toIso8601String(),
      ],
    );
  }

  void clearHistory(AppMode mode) =>
      database.execute('DELETE FROM history WHERE mode=?', [mode.name]);
  List<ArtistEntry> artists(AppMode mode) => database
      .select('SELECT payload FROM artists WHERE mode=? ORDER BY key', [
        mode.name,
      ])
      .map((r) => ArtistEntry.fromJson(_json(r['payload'])))
      .toList();
  void saveArtist(ArtistEntry artist) {
    if (artist.name.trim().isEmpty) {
      throw const FormatException('Enter an artist name.');
    }
    database.execute(
      'INSERT INTO artists VALUES (?,?,?) ON CONFLICT(key) DO UPDATE SET payload=excluded.payload',
      [
        '${artist.mode.name}:${artist.sourceId}:${artist.kind}:${artist.name}',
        artist.mode.name,
        jsonEncode(artist.toJson()),
      ],
    );
  }

  void removeArtist(ArtistEntry artist) => database.execute(
    'DELETE FROM artists WHERE key=?',
    ['${artist.mode.name}:${artist.sourceId}:${artist.kind}:${artist.name}'],
  );
  Map<String, dynamic>? portable(String key) {
    final r = database.select('SELECT payload FROM portable WHERE key=?', [
      key,
    ]);
    return r.isEmpty ? null : _json(r.first['payload']);
  }

  void setPortable(String key, Map<String, dynamic> value) => database.execute(
    'INSERT INTO portable VALUES (?,?) ON CONFLICT(key) DO UPDATE SET payload=excluded.payload',
    [key, jsonEncode(value)],
  );
  List<Map<String, dynamic>> downloads() => database
      .select('SELECT payload FROM downloads')
      .map((r) => _json(r['payload']))
      .toList();
  void saveDownload(String key, Map<String, dynamic> value) => database.execute(
    'INSERT INTO downloads VALUES (?,?) ON CONFLICT(item_key) DO UPDATE SET payload=excluded.payload',
    [key, jsonEncode(value)],
  );
  void removeDownload(String key) =>
      database.execute('DELETE FROM downloads WHERE item_key=?', [key]);
  static Map<String, dynamic> _json(dynamic value) =>
      Map<String, dynamic>.from(jsonDecode(value as String) as Map);
  void close() => database.close();
}
