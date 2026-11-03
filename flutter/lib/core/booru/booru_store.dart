import 'dart:convert';

import 'package:flutter/foundation.dart';

import '../challenge/challenge_store.dart';
import '../storage/app_database.dart';
import '../storage/folder_rules.dart';
import '../support/preferences.dart';
import '../support/sql_database.dart';
import '../support/swift_json.dart';
import '../taste/taste_models.dart';
import '../taste/taste_store.dart';
import 'booru_models.dart';

class FavoriteRecord {
  const FavoriteRecord({required this.post, required this.folderID, required this.savedAt});
  final BooruPost post;
  final String folderID;
  final double savedAt; // seconds since 1970
}

/// API keys never enter SQLite, preferences, media requests, exports or logs.
/// The Android Keystore implementation arrives with the server settings.
abstract interface class BooruCredentialStore {
  BooruCredentials read(String serverID);
  void save(BooruCredentials credentials, String serverID);
}

class MemoryCredentialStore implements BooruCredentialStore {
  final _values = <String, BooruCredentials>{};
  @override
  BooruCredentials read(String serverID) => _values[serverID] ?? const BooruCredentials();
  @override
  void save(BooruCredentials credentials, String serverID) => credentials.isEmpty ? _values.remove(serverID) : _values[serverID] = credentials;
}

/// Image-mode storage. Same tables and migration names as the native `booru.sqlite`.
/// `revision` changes notify listeners, as the native `@Observable` revision does.
class BooruStore extends ChangeNotifier implements SmartFolderLibrary {
  BooruStore({String? path, required this.preferences, BooruCredentialStore? credentials})
    : database = path == null ? SqlDatabase.inMemory() : SqlDatabase.open(path),
      credentials = credentials ?? MemoryCredentialStore() {
    _migrator.migrate(database);
    reload();
  }

  BooruStore.inMemory({AppPreferences? preferences}) : this(preferences: preferences ?? AppPreferences.memory());

  final SqlDatabase database;
  final AppPreferences preferences;
  final BooruCredentialStore credentials;

  List<BooruServer> servers = [];
  String selectedServerID = '';
  List<String> selectedServerIDs = [];
  int _revision = 0;
  String? error;

  int get revision => _revision;
  set revision(int value) {
    _revision = value;
    notifyListeners();
  }

  List<BooruServer> get selectedServers => servers.where((server) => selectedServerIDs.contains(server.id)).toList();
  BooruServer? get selectedServer => servers.where((server) => server.id == selectedServerID).firstOrNull;

  SqlMigrator get _migrator {
    final migrations = SqlMigrator();
    migrations.registerMigration('booru_v1', (db) {
      db.execute('''
        CREATE TABLE settings (key TEXT PRIMARY KEY, value TEXT NOT NULL);
        CREATE TABLE servers (id TEXT PRIMARY KEY, payload BLOB NOT NULL, position INTEGER NOT NULL);
        CREATE TABLE favorites (server_id TEXT NOT NULL, post_id INTEGER NOT NULL, payload BLOB NOT NULL, saved_at DOUBLE NOT NULL, PRIMARY KEY(server_id, post_id));
        CREATE TABLE history (server_id TEXT NOT NULL, query TEXT NOT NULL, used_at DOUBLE NOT NULL, PRIMARY KEY(server_id, query));
        CREATE TABLE saved_tags (server_id TEXT NOT NULL, name TEXT NOT NULL, kind TEXT NOT NULL, PRIMARY KEY(server_id, name, kind));
        CREATE INDEX favorite_date ON favorites(server_id, saved_at DESC);
        ''');
      // Servers are added only by explicit address entry, import, or library sync.
    });
    migrations.registerMigration('booru_v2_folders', (db) {
      db.execute('''
        CREATE TABLE folders (id TEXT PRIMARY KEY, name TEXT NOT NULL, color INTEGER NOT NULL, position INTEGER NOT NULL);
        INSERT INTO folders VALUES ('unsorted', '', 4284922736, 0);
        ALTER TABLE favorites ADD COLUMN folder_id TEXT NOT NULL DEFAULT 'unsorted';
        CREATE INDEX favorite_folder ON favorites(folder_id, saved_at DESC);
        ''');
    });
    // The native step re-labels servers saved by early iOS builds. An Android
    // library is created after it, with no servers to change, so only the name is recorded.
    migrations.registerMigration('booru_v3_legacy_engine', (_) {});
    migrations.registerMigration('booru_v4_canonical_servers', (db) {
      final servers = _fetchServers(db);
      final identities = <String, String>{};
      for (final server in servers) {
        final target = identities[server.canonicalAddress];
        if (target == null) {
          identities[server.canonicalAddress] = server.id;
          continue;
        }
        for (final row in db.rows('SELECT * FROM favorites WHERE server_id = ?', [server.id])) {
          final post = _decodePost(row['payload']).onServer(target);
          db.execute('INSERT OR IGNORE INTO favorites VALUES (?, ?, ?, ?, ?)', [
            target,
            post.postID,
            encodeSwiftJson(post.toJson()),
            row['saved_at'],
            row['folder_id'],
          ]);
        }
        db.execute('INSERT OR IGNORE INTO history SELECT ?, query, used_at FROM history WHERE server_id = ?', [target, server.id]);
        db.execute('INSERT OR IGNORE INTO saved_tags SELECT ?, name, kind FROM saved_tags WHERE server_id = ?', [target, server.id]);
        final oldKey = 'blacklist.${server.id}', newKey = 'blacklist.$target';
        final rules = db.value<String>('SELECT value FROM settings WHERE key = ?', [oldKey]);
        if (rules != null) {
          final existing = db.value<String>('SELECT value FROM settings WHERE key = ?', [newKey]) ?? '';
          db.execute('INSERT OR REPLACE INTO settings VALUES (?, ?)', [
            newKey,
            [existing, rules].where((value) => value.isNotEmpty).join('\n'),
          ]);
        }
        for (final table in ['favorites', 'history', 'saved_tags']) {
          db.execute('DELETE FROM $table WHERE server_id = ?', [server.id]);
        }
        db.execute('DELETE FROM settings WHERE key = ?', [oldKey]);
        db.execute('DELETE FROM servers WHERE id = ?', [server.id]);
        final raw = db.value<String>("SELECT value FROM settings WHERE key = 'selected_servers'");
        final ids = raw == null ? null : _decodeStrings(raw);
        if (ids != null) {
          final mapped = ids.map((id) => id == server.id ? target : id).toSet().toList();
          db.execute("UPDATE settings SET value = ? WHERE key = 'selected_servers'", [encodeSwiftJsonString(mapped)]);
        }
      }
    });
    migrations.registerMigration('booru_v5_site_folders', (db) {
      for (final server in _fetchServers(db)) {
        final count = db.value<int>("SELECT COUNT(*) FROM favorites WHERE server_id = ? AND folder_id = 'unsorted'", [server.id]) ?? 0;
        if (count > 0) {
          final folder = defaultFolder(server.id, db);
          db.execute("UPDATE favorites SET folder_id = ? WHERE server_id = ? AND folder_id = 'unsorted'", [folder, server.id]);
        }
      }
    });
    migrations.registerMigration('booru_v6_import_site_folders', organizeLegacyImportsIn);
    migrations.registerMigration('booru_v7_taste', TasteStore.migrate);
    migrations.registerMigration('booru_v8_visual_fingerprints', VisualFingerprintStore.migrate);
    migrations.registerMigration('booru_v9_visual_cleanup', VisualFingerprintStore.installDeletionTrigger);
    migrations.registerMigration('booru_v10_challenges', ChallengeStore.migrate);
    migrations.registerMigration('booru_v11_optional_unsorted', (db) {
      db.execute("DELETE FROM folders WHERE id = 'unsorted' AND color = 4284922736 AND NOT EXISTS(SELECT 1 FROM favorites WHERE folder_id = 'unsorted')");
    });
    return migrations;
  }

  static BooruPost _decodePost(Object? payload) => BooruPost.fromJson(decodeJsonObject(payload as Uint8List));
  static BooruServer _decodeServer(Object? payload) => BooruServer.fromJson(decodeJsonObject(payload as Uint8List));
  static List<BooruServer> _fetchServers(SqlDatabase db) =>
      db.rows('SELECT payload FROM servers ORDER BY position').map((row) => _decodeServer(row['payload'])).toList();

  static List<String>? _decodeStrings(String raw) {
    try {
      return (jsonDecode(raw) as List).map(jsonString).toList();
    } on Object {
      return null;
    }
  }

  void reload() {
    servers = database.read(_fetchServers);
    final legacy = setting('selected_server') ?? servers.firstOrNull?.id ?? '';
    final raw = setting('selected_servers');
    final saved = (raw == null ? null : _decodeStrings(raw)) ?? [legacy];
    selectedServerIDs = servers.map((server) => server.id).where(saved.contains).toList();
    selectedServerID = selectedServerIDs.firstOrNull ?? '';
  }

  void refresh() {
    reload();
    revision += 1;
  }

  /// Explicit single-server selection is used for links/setup; toolbar selection is additive.
  void select(BooruServer server) => setSelectedServers([server.id]);

  void toggleServer(BooruServer server) {
    final ids = [...selectedServerIDs];
    if (ids.contains(server.id)) {
      ids.remove(server.id);
    } else {
      ids.add(server.id);
    }
    setSelectedServers(ids);
  }

  void setSelectedServers(List<String> ids) {
    final valid = servers.map((server) => server.id).where(ids.contains).toList();
    setSetting('selected_servers', encodeSwiftJsonString(valid));
    selectedServerIDs = valid;
    selectedServerID = valid.firstOrNull ?? '';
  }

  void saveServer(BooruServer server) {
    if (servers.any((other) => other.id != server.id && other.canonicalAddress == server.canonicalAddress)) {
      throw const BooruError(BooruErrorKind.duplicateServer);
    }
    final index = servers.indexWhere((other) => other.id == server.id);
    final position = index >= 0 ? index : servers.length;
    database.write((db) => db.execute('INSERT OR REPLACE INTO servers VALUES (?, ?, ?)', [server.id, encodeSwiftJson(server.toJson()), position]));
    reload();
    revision += 1;
  }

  void deleteServer(BooruServer server) {
    credentials.save(const BooruCredentials(), server.id);
    database.write((db) {
      for (final payload in db.column<Uint8List>('SELECT payload FROM favorites WHERE server_id = ?', [server.id])) {
        TasteStore.record(TasteEventKind.remove, tasteItem(_decodePost(payload), db), db);
      }
      db.execute('DELETE FROM servers WHERE id = ?', [server.id]);
      for (final table in ['favorites', 'history', 'saved_tags']) {
        db.execute('DELETE FROM $table WHERE server_id = ?', [server.id]);
      }
      db.execute('DELETE FROM settings WHERE key = ?', ['blacklist.${server.id}']);
    });
    reload();
    revision += 1;
  }

  List<BooruPost> favoritesOn(String serverID) => favorites([serverID]);

  Set<String> get favoriteIDs =>
      database.read((db) => {for (final row in db.rows('SELECT server_id, post_id FROM favorites')) '${row['server_id']}:${row['post_id']}'});

  bool isFavorite(BooruPost post) => favoriteIDs.contains(post.id);

  void toggleFavorite(BooruPost post, {DiscoveryContext? context}) {
    database.write((db) {
      db.execute('DELETE FROM favorites WHERE server_id = ? AND post_id = ?', [post.serverID, post.postID]);
      final adding = db.changesCount == 0;
      if (adding) {
        final folder = BooruStoreFolderRules.smartDestination(post, defaultFolder(post.serverID, db), db, preferences.defaults);
        db.execute('INSERT INTO favorites (server_id, post_id, payload, saved_at, folder_id) VALUES (?, ?, ?, ?, ?)', [
          post.serverID,
          post.postID,
          encodeSwiftJson(post.toJson()),
          unixSeconds(),
          folder,
        ]);
      }
      TasteStore.record(adding ? TasteEventKind.save : TasteEventKind.remove, tasteItem(post, db), db, context: context);
    });
    revision += 1;
  }

  List<BooruPost> favorites(List<String> serverIDs, {String? folderID}) {
    if (serverIDs.isEmpty) return [];
    final set = serverIDs.toSet();
    return [
      for (final record in favoriteRecords())
        if (set.contains(record.post.serverID) && (folderID == null || record.folderID == folderID)) record.post,
    ];
  }

  List<FavoriteRecord> favoriteRecords() => database.read(
    (db) => [
      for (final row in db.rows('SELECT payload, folder_id, saved_at FROM favorites ORDER BY saved_at DESC'))
        FavoriteRecord(post: _decodePost(row['payload']), folderID: row['folder_id'] as String, savedAt: (row['saved_at'] as num).toDouble()),
    ],
  );

  List<BooruPost> visibleFavorites({String? folderID, String query = ''}) {
    final filters = {for (final server in servers) server.id: BooruBlacklist(blacklist(server.id))};
    final lowered = query.toLowerCase();
    return favorites(servers.map((server) => server.id).toList(), folderID: folderID).where((post) {
      if (filters[post.serverID]?.contains(post) ?? false) return false;
      return query.isEmpty || post.tags.join(' ').toLowerCase().contains(lowered) || '${post.postID}'.contains(query);
    }).toList();
  }

  Map<String, double> favoriteSavedDates() => {for (final record in favoriteRecords()) record.post.id: record.savedAt};

  List<BooruFolder> folders() => database.read((db) {
    final smart = BooruStoreFolderRules.fetchFolderRules(db).where((rule) => rule.isActive).map((rule) => rule.folder).toSet();
    return [
      for (final row in db.rows('SELECT * FROM folders ORDER BY position, name'))
        BooruFolder(id: row['id'] as String, name: row['name'] as String, color: row['color'] as int, isSmart: smart.contains(row['id'])),
    ];
  });

  String saveFolder({String? id, required String name, int? color}) {
    final folderID = id ?? uuidString();
    final trimmedName = name.trim();
    if (trimmedName.isEmpty || folderID == 'unsorted') throw const BooruError(BooruErrorKind.invalidResponse);
    database.write((db) {
      final existing = db.value<int>('SELECT color FROM folders WHERE id = ?', [folderID]);
      final resolved = color ?? existing ?? AppDatabase.nextFolderColor(existingColors: db.column<int>('SELECT color FROM folders'));
      db.execute(
        'INSERT INTO folders VALUES (?, ?, ?, (SELECT COUNT(*) FROM folders)) ON CONFLICT(id) DO UPDATE SET name = excluded.name, color = excluded.color',
        [folderID, trimmedName, resolved],
      );
    });
    revision += 1;
    return folderID;
  }

  static void ensureUnsorted(SqlDatabase db) => db.execute("INSERT OR IGNORE INTO folders VALUES ('unsorted', '', 4284922736, 0)");

  void deleteFolder(String id) {
    database.write((db) {
      final hasWorks = db.exists('SELECT EXISTS(SELECT 1 FROM favorites WHERE folder_id = ?)', [id]);
      if (id == 'unsorted' && hasWorks) throw const FolderDeletionError();
      if (hasWorks) {
        ensureUnsorted(db);
        db.execute("UPDATE favorites SET folder_id = 'unsorted' WHERE folder_id = ?", [id]);
      }
      db.execute('DELETE FROM folders WHERE id = ?', [id]);
      db.execute('DELETE FROM settings WHERE key = ?', [FolderRule.keyPrefix + id]);
    });
    revision += 1;
  }

  String? folderIDFor(BooruPost post) =>
      database.read((db) => db.value<String>('SELECT folder_id FROM favorites WHERE server_id = ? AND post_id = ?', [post.serverID, post.postID]));

  void saveFavorite(BooruPost post, {String? folderID, DiscoveryContext? context}) {
    database.write((db) {
      final existing = db.value<String>('SELECT folder_id FROM favorites WHERE server_id = ? AND post_id = ?', [post.serverID, post.postID]);
      final target = folderID ?? existing ?? BooruStoreFolderRules.smartDestination(post, defaultFolder(post.serverID, db), db, preferences.defaults);
      if (!db.exists('SELECT EXISTS(SELECT 1 FROM folders WHERE id = ?)', [target])) throw const BooruError(BooruErrorKind.invalidResponse);
      db.execute(
        'INSERT INTO favorites (server_id, post_id, payload, saved_at, folder_id) VALUES (?, ?, ?, ?, ?) ON CONFLICT(server_id, post_id) DO UPDATE SET payload = excluded.payload, folder_id = excluded.folder_id',
        [post.serverID, post.postID, encodeSwiftJson(post.toJson()), unixSeconds(), target],
      );
      final item = tasteItem(post, db);
      if (existing == null && context != null) {
        TasteStore.record(TasteEventKind.save, item, db, context: context);
      } else if (existing == null) {
        TasteStore.record(TasteEventKind.imported, item, db);
      } else {
        TasteStore.record(TasteEventKind.metadata, item, db);
      }
    });
    revision += 1;
  }

  void organizeLegacyImports() => database.write(organizeLegacyImportsIn);

  /// Repair the former shared import destination without moving user-created folders.
  static void organizeLegacyImportsIn(SqlDatabase db) {
    for (final serverID in db.column<String>("SELECT DISTINCT server_id FROM favorites WHERE folder_id = 'anime-boxes'")) {
      final folder = defaultFolder(serverID, db);
      db.execute("UPDATE favorites SET folder_id = ? WHERE server_id = ? AND folder_id = 'anime-boxes'", [folder, serverID]);
    }
    db.execute("DELETE FROM folders WHERE id = 'anime-boxes' AND NOT EXISTS (SELECT 1 FROM favorites WHERE folder_id = 'anime-boxes')");
  }

  static String defaultFolder(String serverID, SqlDatabase db) {
    final data = db.value<Uint8List>('SELECT payload FROM servers WHERE id = ?', [serverID]);
    if (data == null) throw const BooruError(BooruErrorKind.invalidServer);
    final server = _decodeServer(data);
    // Canonical address is stable across devices and server ID remapping.
    final id = 'site:${server.canonicalAddress}';
    if (db.value<String>('SELECT id FROM folders WHERE id = ?', [id]) == null) {
      final color = AppDatabase.nextFolderColor(existingColors: db.column<int>('SELECT color FROM folders'));
      db.execute('INSERT INTO folders VALUES (?, ?, ?, (SELECT COUNT(*) FROM folders))', [id, server.displayName, color]);
    }
    return id;
  }

  static TasteItem tasteItem(BooruPost post, SqlDatabase db) {
    final data = db.value<Uint8List>('SELECT payload FROM servers WHERE id = ?', [post.serverID]);
    final source = data == null ? post.serverID : _decodeServer(data).canonicalAddress;
    return TasteItem(source: source, id: post.postID, tags: post.tags, metadata: post.metadataTags ?? []);
  }

  List<String> history(String serverID, {int? limit = 500}) => database.read(
    (db) => db.column<String>('SELECT query FROM history WHERE server_id = ? AND used_at >= ? ORDER BY used_at DESC LIMIT ?', [
      serverID,
      SearchRetention.cutoff(preferences.booruDefaults),
      limit ?? -1,
    ]),
  );

  void recordSearch(String query, {required String serverID}) {
    final value = query.trim();
    if (value.isEmpty) return;
    database.write((db) {
      db.execute('DELETE FROM history WHERE used_at < ?', [SearchRetention.cutoff(preferences.booruDefaults)]);
      db.execute('INSERT OR REPLACE INTO history VALUES (?, ?, ?)', [serverID, value, unixSeconds()]);
      db.execute('DELETE FROM history WHERE server_id = ? AND query NOT IN (SELECT query FROM history WHERE server_id = ? ORDER BY used_at DESC LIMIT 500)', [
        serverID,
        serverID,
      ]);
    });
    revision += 1;
  }

  void clearHistory(String serverID) {
    database.write((db) => db.execute('DELETE FROM history WHERE server_id = ?', [serverID]));
    revision += 1;
  }

  List<String> savedTags(String serverID, {String kind = 'tag'}) =>
      database.read((db) => db.column<String>('SELECT name FROM saved_tags WHERE server_id = ? AND kind = ? ORDER BY name', [serverID, kind]));

  void toggleTag(String name, {required String serverID, String kind = 'tag'}) {
    database.write((db) {
      db.execute('DELETE FROM saved_tags WHERE server_id = ? AND name = ? AND kind = ?', [serverID, name, kind]);
      if (db.changesCount == 0) db.execute('INSERT INTO saved_tags VALUES (?, ?, ?)', [serverID, name, kind]);
    });
    revision += 1;
  }

  String blacklist(String serverID) => setting('blacklist.$serverID') ?? '';
  void setBlacklist(String text, {required String serverID}) => setSetting('blacklist.$serverID', text);

  String? setting(String key) => database.read((db) => db.value<String>('SELECT value FROM settings WHERE key = ?', [key]));

  void setSetting(String key, String value) {
    database.write((db) => db.execute('INSERT OR REPLACE INTO settings VALUES (?, ?)', [key, value]));
    revision += 1;
  }

  void removeSetting(String key) {
    database.write((db) => db.execute('DELETE FROM settings WHERE key = ?', [key]));
    revision += 1;
  }

  // MARK: - Search library (SearchLibrary.swift)

  void deleteSearch(String query, {required String serverID}) {
    database.write((db) => db.execute('DELETE FROM history WHERE server_id = ? AND query = ?', [serverID, query]));
    refresh();
  }

  void reorderFolders(List<String> ids) {
    database.write((db) {
      final existing = db.column<String>('SELECT id FROM folders ORDER BY position, name');
      final seen = <String>{};
      final completeOrder = [...ids, ...existing].where((id) => existing.contains(id) && seen.add(id)).toList();
      for (final (position, id) in completeOrder.indexed) {
        db.execute('UPDATE folders SET position = ? WHERE id = ?', [position, id]);
      }
      db.execute("INSERT OR REPLACE INTO settings VALUES ('folder_order', ?)", [encodeSwiftJsonString(completeOrder)]);
    });
    refresh();
  }

  void setFolderColor(String id, int color) {
    database.write((db) => db.execute('UPDATE folders SET color = ? WHERE id = ?', [color, id]));
    refresh();
  }

  void removeFavorites(List<BooruPost> posts) {
    database.write((db) {
      for (final post in posts) {
        TasteStore.record(TasteEventKind.remove, tasteItem(post, db), db);
        db.execute('DELETE FROM favorites WHERE server_id = ? AND post_id = ?', [post.serverID, post.postID]);
      }
    });
    refresh();
  }

  void moveFavorites(List<BooruPost> posts, String folderID) {
    database.write((db) {
      if (!db.exists('SELECT EXISTS(SELECT 1 FROM folders WHERE id = ?)', [folderID])) throw const BooruError(BooruErrorKind.invalidResponse);
      for (final post in posts) {
        db.execute('UPDATE favorites SET folder_id = ? WHERE server_id = ? AND post_id = ?', [folderID, post.serverID, post.postID]);
      }
    });
    refresh();
  }

  DateTime? savedDate(BooruPost post) {
    final seconds = database.read((db) => db.value<double>('SELECT saved_at FROM favorites WHERE server_id = ? AND post_id = ?', [post.serverID, post.postID]));
    return seconds == null ? null : DateTime.fromMicrosecondsSinceEpoch((seconds * 1e6).round(), isUtc: true);
  }

  void pruneSearchHistory() {
    try {
      database.write((db) => db.execute('DELETE FROM history WHERE used_at < ?', [SearchRetention.cutoff(preferences.booruDefaults)]));
      refresh();
    } on Object {
      // Pruning is best effort, as in the native app.
    }
  }

  // MARK: - SmartFolderLibrary

  @override
  List<SmartFolderChoice> folderChoices() => ruleFolderChoices();
  @override
  Set<String> defaultRuleSources() => ruleDefaultSources();
  @override
  FolderRule? rule(String forFolder) => ruleForFolder(forFolder);
  @override
  List<FolderRule> smartRules() => ruleList();
  @override
  int matchingCount(FolderRule rule) => matchingRuleCount(rule);
  @override
  String createRuleFolder(String named) => saveFolder(name: named);
  @override
  void saveRule(FolderRule rule) => saveFolderRule(rule);
  @override
  void deleteRule(String forFolder) => deleteFolderRule(forFolder);
  @override
  void fill(FolderRule rule) => fillRule(rule);
}
