import 'dart:convert';

import 'package:sqlite3/sqlite3.dart';

import '../core/content.dart';
import '../core/library.dart';
import '../core/folder_color.dart';

/// Counts plus at most four decoded covers for a library's folder grid.
class LibraryOverview {
  const LibraryOverview({
    required this.totalCount,
    required this.unfiled,
    required this.folders,
  });
  final int totalCount;
  final LibraryFolderOverview unfiled;
  final Map<String, LibraryFolderOverview> folders;
}

class LibraryFolderOverview {
  const LibraryFolderOverview({this.count = 0, this.previews = const []});
  final int count;
  final List<ContentItem> previews;
}

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
  bool _booruFoldersNeedRepair = true;
  bool _repairingBooruFolders = false;

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
      _booruFoldersNeedRepair = true;
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
    _booruFoldersNeedRepair = true;
    SourceConfig.validateUrl(source.baseUrl.toString());
    database.execute(
      'INSERT INTO sources VALUES (?,?,?) ON CONFLICT(id) DO UPDATE SET mode=excluded.mode,payload=excluded.payload',
      [source.id, source.mode.name, jsonEncode(source.toJson())],
    );
  }

  void removeSource(String id) {
    database.execute('DELETE FROM sources WHERE id=?', [id]);
    _booruFoldersNeedRepair = true;
  }

  List<LibraryFolder> folders(AppMode mode) {
    if (mode == AppMode.booru) _repairBooruSiteFolders();
    final legacy = mode == AppMode.booru ? _legacyBooruFolderIds() : <String>{};
    return _storedFolders(mode)
        .where((folder) => !legacy.contains(folder.id))
        .toList();
  }

  List<LibraryFolder> _storedFolders(AppMode mode) => database
      .select('SELECT * FROM folders WHERE mode=? ORDER BY position,name', [
        mode.name,
      ])
      .map((r) => LibraryFolder.fromJson(r))
      .toList();

  // Native site folders are real folders, created on first save. Keep legacy
  // rows intact for imported metadata, but never expose a shared image Unfiled.
  Set<String> _legacyBooruFolderIds() {
    final metadata = portable('backup.images')?['folderMetadata'] as Map? ?? {};
    return {
      'unsorted',
      'anime-boxes',
      'builtin-unfiled-booru',
      for (final source in sources(AppMode.booru)) 'site:source:${source.id}',
      for (final entry in metadata.entries)
        if (entry.value is Map &&
            [
              'unsorted',
              'anime-boxes',
            ].contains((entry.value as Map)['nativeID']))
          entry.key as String,
    };
  }

  LibraryFolder _defaultBooruFolder(String sourceId) {
    final source = sources(AppMode.booru)
        .where((source) => source.id == sourceId)
        .firstOrNull;
    final id = source == null
        ? 'site:source:$sourceId'
        : 'site:${source.canonicalAddress}';
    final existing = _storedFolders(AppMode.booru);
    final metadata = portable('backup.images')?['folderMetadata'] as Map? ?? {};
    final current = existing
        .where(
          (folder) =>
              folder.id == id ||
              (metadata[folder.id] is Map &&
                  (metadata[folder.id] as Map)['nativeID'] == id),
        )
        .firstOrNull;
    if (current != null) return current;
    final name = source?.name
        .trim()
        .replaceFirst(RegExp(r'^https?://', caseSensitive: false), '')
        .replaceFirst(RegExp(r'/+$'), '');
    final fallback = source == null
        ? null
        : existing
              .where((folder) => folder.id == 'site:source:$sourceId')
              .firstOrNull;
    final folder = LibraryFolder(
      id: id,
      mode: AppMode.booru,
      name: fallback != null && fallback.name != sourceId
          ? fallback.name
          : name == null || name.isEmpty
          ? (source?.baseUrl.host ??
                (sourceId.isEmpty ? 'Unknown site' : sourceId))
          : name,
      color:
          fallback?.color ??
          FolderColors.next(existing.map((folder) => folder.color).toList()),
      position: fallback?.position ?? existing.length,
    );
    saveFolder(folder);
    return folder;
  }

  void _repairBooruSiteFolders() {
    if (!_booruFoldersNeedRepair || _repairingBooruFolders) return;
    _repairingBooruFolders = true;
    try {
      transaction(() {
        final legacy = _legacyBooruFolderIds();
        final placeholders = List.filled(legacy.length, '?').join(',');
        // Extract only identity for unclassified rows; never decode full works.
        final rows = database.select(
          "SELECT i.key, json_extract(i.payload, '\$.sourceId') AS source_id FROM items i WHERE i.mode='booru' AND NOT EXISTS (SELECT 1 FROM memberships m WHERE m.item_key=i.key AND m.folder_id NOT IN ($placeholders))",
          legacy.toList(),
        );
        final destinations = <String, String>{};
        for (final row in rows) {
          final sourceId = row['source_id'] as String;
          final folderId = destinations.putIfAbsent(
            sourceId,
            () => _defaultBooruFolder(sourceId).id,
          );
          database.execute('DELETE FROM memberships WHERE item_key=?', [
            row['key'],
          ]);
          database.execute('INSERT INTO memberships VALUES (?,?)', [
            row['key'],
            folderId,
          ]);
        }
      });
      _booruFoldersNeedRepair = false;
    } finally {
      _repairingBooruFolders = false;
    }
  }

  /// User creation follows each native library's duplicate-name and color rules.
  /// Import/upsert paths keep their explicit colors through [saveFolder].
  LibraryFolder createFolder(
    String name, {
    required String id,
    required AppMode mode,
    int? color,
  }) => transaction(() {
    final trimmed = name.trim();
    if (trimmed.isEmpty) {
      throw const FormatException('A folder needs a name and valid color.');
    }
    final existing = folders(mode);
    if (mode == AppMode.manga) {
      final duplicate = existing
          .where((folder) => folder.name == trimmed)
          .firstOrNull;
      if (duplicate != null) return duplicate;
    }
    final current = existing.where((folder) => folder.id == id).firstOrNull;
    final folder = LibraryFolder(
      id: id,
      mode: mode,
      name: trimmed,
      color:
          color ??
          current?.color ??
          FolderColors.next(existing.map((folder) => folder.color).toList()),
      position:
          current?.position ??
          (mode == AppMode.manga
              ? existing.fold<int>(
                      0,
                      (max, folder) =>
                          folder.position > max ? folder.position : max,
                    ) +
                    1
              : existing.length),
    );
    saveFolder(folder);
    return folder;
  });

  void saveFolder(LibraryFolder folder) {
    if (folder.mode == AppMode.booru) _booruFoldersNeedRepair = true;
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

  void deleteFolder(String id) {
    database.execute('DELETE FROM folders WHERE id=?', [id]);
    _booruFoldersNeedRepair = true;
  }

  List<SavedItem> items(AppMode mode, {String? folderId, String query = ''}) {
    if (mode == AppMode.booru) _repairBooruSiteFolders();
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

  /// Metadata-only membership lookup: avoids decoding a saved work just to
  /// determine whether its key is present. Startup may request both modes.
  Set<String> savedKeys([AppMode? mode]) => database
      .select(
        mode == null
            ? 'SELECT key FROM items'
            : 'SELECT key FROM items WHERE mode=?',
        mode == null ? const [] : [mode.name],
      )
      .map((row) => row['key'] as String)
      .toSet();

  /// A grid asks only about the small group of works it is about to build.
  Set<String> savedKeysMatching(Iterable<String> keys) {
    final requested = keys.toSet().toList();
    final result = <String>{};
    for (var start = 0; start < requested.length; start += 400) {
      final group = requested.skip(start).take(400).toList();
      result.addAll(
        database
            .select(
              'SELECT key FROM items WHERE key IN (${List.filled(group.length, '?').join(',')})',
              group,
            )
            .map((row) => row['key'] as String),
      );
    }
    return result;
  }

  /// Like native folder snapshots, read counts and only four covers per folder.
  /// Full saved records stay in the collection route rather than this overview.
  LibraryOverview libraryOverview(
    AppMode mode, {
    Set<String> unfiledFolderIds = const {},
  }) {
    if (mode == AppMode.booru) _repairBooruSiteFolders();
    final counts = <String, int>{
      for (final row in database.select(
        'SELECT m.folder_id, COUNT(*) AS total FROM memberships m JOIN items i ON i.key=m.item_key WHERE i.mode=? GROUP BY m.folder_id',
        [mode.name],
      ))
        row['folder_id'] as String: row['total'] as int,
    };
    final previews = <String, List<ContentItem>>{};
    for (final row in database.select(
      'WITH ranked AS (SELECT m.folder_id, i.key, ROW_NUMBER() OVER (PARTITION BY m.folder_id ORDER BY i.saved_at DESC) AS rank FROM memberships m JOIN items i ON i.key=m.item_key WHERE i.mode=?) SELECT r.folder_id,i.payload FROM ranked r JOIN items i ON i.key=r.key WHERE r.rank<=4 ORDER BY r.folder_id,r.rank',
      [mode.name],
    )) {
      previews
          .putIfAbsent(row['folder_id'] as String, () => [])
          .add(ContentItem.fromJson(_json(row['payload'])));
    }
    final unfiled = unfiledFolderIds.isEmpty
        ? 'NOT EXISTS (SELECT 1 FROM memberships m WHERE m.item_key=i.key)'
        : 'NOT EXISTS (SELECT 1 FROM memberships m WHERE m.item_key=i.key AND m.folder_id NOT IN (${List.filled(unfiledFolderIds.length, '?').join(',')}))';
    final args = <Object?>[mode.name, ...unfiledFolderIds];
    return LibraryOverview(
      totalCount:
          database.select('SELECT COUNT(*) AS total FROM items WHERE mode=?', [
                mode.name,
              ]).single['total']
              as int,
      unfiled: LibraryFolderOverview(
        count:
            database
                    .select(
                      'SELECT COUNT(*) AS total FROM items i WHERE i.mode=? AND $unfiled',
                      args,
                    )
                    .single['total']
                as int,
        previews: [
          for (final row in database.select(
            'SELECT i.payload FROM items i WHERE i.mode=? AND $unfiled ORDER BY i.saved_at DESC LIMIT 4',
            args,
          ))
            ContentItem.fromJson(_json(row['payload'])),
        ],
      ),
      folders: {
        for (final entry in counts.entries)
          entry.key: LibraryFolderOverview(
            count: entry.value,
            previews: previews[entry.key] ?? const [],
          ),
      },
    );
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
      var targetFolderIds = folderIds;
      final previousSaved = saved(item.key);
      final previous = previousSaved?.item;
      if (item.mode == AppMode.booru) {
        final requested = targetFolderIds ?? previousSaved?.folderIds ?? [];
        final legacy = _legacyBooruFolderIds();
        targetFolderIds = requested.isEmpty || requested.every(legacy.contains)
            ? [_defaultBooruFolder(item.sourceId).id]
            : requested;
        _booruFoldersNeedRepair = true;
      }
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
          targetFolderIds != null &&
          targetFolderIds.where((id) => id != 'unsorted').toSet().length > 1) {
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
      if (targetFolderIds != null) {
        database.execute('DELETE FROM memberships WHERE item_key=?', [
          item.key,
        ]);
        for (final id in targetFolderIds.toSet()) {
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

  void pruneHistory(AppMode mode, DateTime before) => database.execute(
    'DELETE FROM history WHERE mode=? AND used_at < ?',
    [mode.name, before.toUtc().toIso8601String()],
  );

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

  void setPortable(String key, Map<String, dynamic> value) {
    if (key == 'backup.images') _booruFoldersNeedRepair = true;
    database.execute(
      'INSERT INTO portable VALUES (?,?) ON CONFLICT(key) DO UPDATE SET payload=excluded.payload',
      [key, jsonEncode(value)],
    );
  }

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
