import 'dart:convert';

import 'package:flutter/foundation.dart';

import '../challenge/challenge_store.dart';
import '../content/site_account.dart';
import '../storage/app_database.dart';
import '../storage/folder_rules.dart';
import '../study/study_store.dart';
import '../support/preferences.dart';
import '../support/sql_database.dart';
import '../support/swift_json.dart';
import '../taste/taste_models.dart';
import '../taste/taste_store.dart';
import 'booru_models.dart';
import '../support/privacy_settings.dart';

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

/// Account details in the device keystore ([SecretStore]), one JSON entry per server.
class SecretCredentialStore implements BooruCredentialStore {
  SecretCredentialStore(this.secrets);
  final SecretStore secrets;

  static String _key(String serverID) => 'booru.credentials.$serverID';

  @override
  BooruCredentials read(String serverID) {
    final raw = secrets.read(_key(serverID));
    if (raw == null) return const BooruCredentials();
    try {
      final json = jsonDecode(raw) as Map<String, Object?>;
      return BooruCredentials(account: json['account'] as String? ?? '', apiKey: json['apiKey'] as String? ?? '').normalized;
    } on Object {
      throw const BooruError(BooruErrorKind.storage);
    }
  }

  @override
  void save(BooruCredentials credentials, String serverID) =>
      secrets.write(_key(serverID), credentials.isEmpty ? null : jsonEncode({'account': credentials.account, 'apiKey': credentials.apiKey}));
}

class MemoryCredentialStore implements BooruCredentialStore {
  final _values = <String, BooruCredentials>{};
  @override
  BooruCredentials read(String serverID) => (_values[serverID] ?? const BooruCredentials()).normalized;
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
  String? _error;
  final _goldRestrictedIDs = <String>{};
  int _snapshotGeneration = 0;
  (int, Set<String>)? _cachedFavoriteIDs;
  (int, List<FavoriteRecord>)? _cachedFavorites;
  (int, List<BooruFolder>)? _cachedFolders;
  int _visibleFavoritesRevision = -1;
  final _visibleFavoritesCache = <(String?, String, bool, String), List<BooruPost>>{};

  /// Safe Mode, read from the app's settings. Safebooru carries only all-ages images, so it is the
  /// one server browsed, and only images saved from it are shown; everything else stays saved,
  /// out of sight.
  bool Function() safeMode = () => false;

  /// Saved screens show the change at once when Safe Mode changes.
  void safeModeChanged() {
    _visibleFavoritesCache.clear();
    _visibleFavoritesRevision = -1;
    notifyListeners();
  }

  /// Whether a saved image may be shown under Safe Mode.
  bool isShownInSafeMode(BooruPost post) => !safeMode() || isSafebooru(post.serverID);

  bool isSafebooru(String serverID) => servers.where((server) => server.id == serverID).firstOrNull?.isSafebooru == true;

  /// The servers that can be chosen to browse: Safebooru alone in Safe Mode.
  List<BooruServer> get selectableServers => safeMode() ? servers.where((server) => server.isSafebooru).toList() : servers;

  /// What was chosen before Safe Mode, chosen again when it is turned off.
  static const _presafeSelectionKey = 'safe_mode.previous_servers';

  /// Warms a newly saved post's preview (the native visual fingerprint prefetch). The app
  /// sets it with the thumbnail cache; the store only reports which post to warm.
  void Function(BooruPost post, BooruServer server)? warmSavedPreview;

  int get revision => _revision;
  set revision(int value) {
    _revision = value;
    notifyListeners();
  }

  String? get error => _error;
  set error(String? value) {
    _error = value;
    notifyListeners();
  }

  /// Runs a store change and shows its failure in [error], as the native `perform` does.
  void perform(void Function() operation) {
    try {
      operation();
    } on BooruError catch (failure) {
      error = failure.errorDescription;
    } on FolderDeletionError catch (failure) {
      error = failure.errorDescription;
    } on Object catch (failure) {
      error = '$failure';
    }
  }

  /// Access restrictions are scoped to this running session, never persisted
  /// as a blacklist or a deletion from the person's saved library.
  Set<String> get confirmedGoldRestrictedIDs => Set.unmodifiable(_goldRestrictedIDs);

  bool isVisible(BooruPost post) => !_goldRestrictedIDs.contains(post.id);

  void recordGoldRestriction(BooruPost post) => recordGoldRestrictions(post.serverID, [post.postID]);

  void recordGoldRestrictions(String serverID, List<int> postIDs) {
    final ids = {for (final id in postIDs.where((id) => id > 0)) '$serverID:$id'};
    if (ids.isEmpty || _goldRestrictedIDs.containsAll(ids)) return;
    _goldRestrictedIDs.addAll(ids);
    notifyListeners();
  }

  void clearGoldRestrictions({String? serverID}) {
    bool matches(String id) {
      if (serverID == null) return true;
      final separator = id.lastIndexOf(':');
      return separator >= 0 && id.substring(0, separator) == serverID;
    }

    if (!_goldRestrictedIDs.any(matches)) return;
    _goldRestrictedIDs.removeWhere(matches);
    notifyListeners();
  }

  /// Sync writes directly to SQLite. Invalidate cached query results at that
  /// commit, before the later revision notification.
  void invalidateSnapshots() {
    _snapshotGeneration += 1;
    _cachedFavoriteIDs = null;
    _cachedFavorites = null;
    _cachedFolders = null;
    _visibleFavoritesCache.clear();
    _visibleFavoritesRevision = -1;
  }

  int get _snapshotVersion => _revision + _snapshotGeneration;

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
          final folder = _legacySiteFolder(server.id, db);
          db.execute("UPDATE favorites SET folder_id = ? WHERE server_id = ? AND folder_id = 'unsorted'", [folder, server.id]);
        }
      }
    });
    migrations.registerMigration('booru_v6_import_site_folders', (db) => organizeLegacyImportsIn(db, legacy: true));
    migrations.registerMigration('booru_v7_taste', TasteStore.migrate);
    migrations.registerMigration('booru_v8_visual_fingerprints', VisualFingerprintStore.migrate);
    migrations.registerMigration('booru_v9_visual_cleanup', VisualFingerprintStore.installDeletionTrigger);
    migrations.registerMigration('booru_v10_challenges', ChallengeStore.migrate);
    migrations.registerMigration('booru_v11_optional_unsorted', (db) {
      db.execute("DELETE FROM folders WHERE id = 'unsorted' AND color = 4284922736 AND NOT EXISTS(SELECT 1 FROM favorites WHERE folder_id = 'unsorted')");
    });
    migrations.registerMigration('booru_v12_vivid_folder_colors', AppDatabase.adoptVividFolderColors);
    // Each server gets folders of its own; a folder with images of several servers becomes one
    // folder of the same name and color in each, and a folder holding nothing stays global.
    migrations.registerMigration('booru_v13_server_folders', (db) {
      db.execute('ALTER TABLE folders ADD COLUMN server_id TEXT');
      assignFolderServers(db);
    });
    migrations.registerMigration('booru_v14_study', StudyStore.migrate);
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
    invalidateSnapshots();
    final updated = database.read(_fetchServers);
    for (final server in servers) {
      if (!updated.contains(server)) clearGoldRestrictions(serverID: server.id);
    }
    servers = updated;
    final legacy = setting('selected_server') ?? servers.firstOrNull?.id ?? '';
    final raw = setting('selected_servers');
    final saved = (raw == null ? null : _decodeStrings(raw)) ?? [legacy];
    // Another device or a restored backup may have chosen other servers; Safe Mode keeps to Safebooru.
    final safe = safeMode();
    selectedServerIDs = [
      for (final server in servers)
        if (saved.contains(server.id) && (!safe || server.isSafebooru)) server.id,
    ];
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
    final safe = safeMode();
    final valid = [
      for (final server in servers)
        if (ids.contains(server.id) && (!safe || server.isSafebooru)) server.id,
    ];
    // In Safe Mode, choosing only other servers leaves Safebooru chosen rather than nothing.
    if (safe && valid.isEmpty && selectedServerIDs.isNotEmpty) return;
    setSetting('selected_servers', encodeSwiftJsonString(valid));
    selectedServerIDs = valid;
    selectedServerID = valid.firstOrNull ?? '';
  }

  /// `enterSafeMode`: Safe Mode browses Safebooru alone, adding it first when it is not among the
  /// servers. The servers chosen until then are remembered for when it is turned off. The app
  /// has already stored the switch, so [safeMode] reads true.
  void enterSafeMode() {
    final chosen = setting('selected_servers') ?? '';
    if (setting(_presafeSelectionKey) == null && chosen.isNotEmpty) setSetting(_presafeSelectionKey, chosen);
    selectSafebooru();
    safeModeChanged();
  }

  /// `leaveSafeMode`: chooses again what was chosen before Safe Mode, or keeps Safebooru when
  /// that is gone.
  void leaveSafeMode() {
    final raw = setting(_presafeSelectionKey);
    if (raw != null) {
      removeSetting(_presafeSelectionKey);
      final previous = _decodeStrings(raw) ?? const <String>[];
      if (previous.any((id) => servers.any((server) => server.id == id))) setSelectedServers(previous);
    }
    safeModeChanged();
  }

  /// At launch with Safe Mode on, a selection another device or a backup made keeps to Safebooru.
  void applySafeMode() {
    if (!safeMode()) return;
    reload();
    if (selectedServers.isEmpty) selectSafebooru();
  }

  void selectSafebooru() {
    final existing = servers.where((server) => server.isSafebooru).firstOrNull;
    if (existing != null) return setSelectedServers([existing.id]);
    final server = BooruServer.safebooru();
    saveServer(server);
    setSelectedServers([server.id]);
  }

  void saveServer(BooruServer server) {
    if (servers.any((other) => other.id != server.id && other.canonicalAddress == server.canonicalAddress)) {
      throw const BooruError(BooruErrorKind.duplicateServer);
    }
    final index = servers.indexWhere((other) => other.id == server.id);
    final position = index >= 0 ? index : servers.length;
    database.write((db) {
      db.execute('INSERT OR REPLACE INTO servers VALUES (?, ?, ?)', [server.id, encodeSwiftJson(server.toJson()), position]);
      // A server has its Uncategorized from the start.
      uncategorized(server.id, db);
    });
    reload();
    // Saving also follows a credentials edit, even when the server address
    // itself is unchanged. A different account may have Gold access.
    clearGoldRestrictions(serverID: server.id);
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
      StudyStore.forget(server.canonicalAddress, db);
      // Its folders go with it; global folders stay.
      for (final id in db.column<String>('SELECT id FROM folders WHERE server_id = ?', [server.id])) {
        db.execute('DELETE FROM settings WHERE key = ?', [FolderRule.keyPrefix + id]);
      }
      db.execute('DELETE FROM folders WHERE server_id = ?', [server.id]);
    });
    reload();
    revision += 1;
  }

  List<BooruPost> favoritesOn(String serverID) => favorites([serverID]);

  /// Read once by the grid so cells observe imports and restored data.
  Set<String> get favoriteIDs {
    final version = _snapshotVersion, cached = _cachedFavoriteIDs;
    if (cached != null && cached.$1 == version) return cached.$2;
    final value = database.read((db) => {for (final row in db.rows('SELECT server_id, post_id FROM favorites')) '${row['server_id']}:${row['post_id']}'});
    _cachedFavoriteIDs = (version, value);
    return value;
  }

  bool isFavorite(BooruPost post) => favoriteIDs.contains(post.id);

  void toggleFavorite(BooruPost post, {DiscoveryContext? context}) {
    var adding = false;
    database.write((db) {
      db.execute('DELETE FROM favorites WHERE server_id = ? AND post_id = ?', [post.serverID, post.postID]);
      adding = db.changesCount == 0;
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
    if (adding) _warmSavedPreview(post);
  }

  void _warmSavedPreview(BooruPost post) {
    final server = servers.where((value) => value.id == post.serverID).firstOrNull;
    if (server == null || (post.previewURL ?? post.sampleURL) == null) return;
    warmSavedPreview?.call(post, server);
  }

  List<BooruPost> favorites(List<String> serverIDs, {String? folderID}) {
    if (serverIDs.isEmpty) return [];
    final set = serverIDs.toSet();
    return [
      for (final record in favoriteRecords())
        if (set.contains(record.post.serverID) && (folderID == null || record.folderID == folderID)) record.post,
    ];
  }

  List<FavoriteRecord> favoriteRecords() {
    final version = _snapshotVersion, cached = _cachedFavorites;
    if (cached != null && cached.$1 == version) return cached.$2;
    final value = database.read(
      (db) => [
        for (final row in db.rows('SELECT payload, folder_id, saved_at FROM favorites ORDER BY saved_at DESC'))
          FavoriteRecord(post: _decodePost(row['payload']), folderID: row['folder_id'] as String, savedAt: (row['saved_at'] as num).toDouble()),
      ],
    );
    _cachedFavorites = (version, value);
    return value;
  }

  /// Favorites search: a post's tags or its number.
  static bool matches(BooruPost post, String query, {String? lowered}) =>
      query.isEmpty || post.tags.join(' ').toLowerCase().contains(lowered ?? query.toLowerCase()) || '${post.postID}'.contains(query);

  /// Without a folder, the images of every folder shown in Saved.
  List<BooruPost> visibleFavorites({String? folderID, String query = ''}) {
    final safe = safeMode();
    final version = _snapshotVersion, key = (folderID, query, safe, folderID == null ? selectedServerIDs.join(',') : '');
    List<BooruPost> shown(List<BooruPost> value) => _goldRestrictedIDs.isEmpty ? value : value.where((post) => !_goldRestrictedIDs.contains(post.id)).toList();
    if (_visibleFavoritesRevision == version) {
      final cached = _visibleFavoritesCache[key];
      if (cached != null) return shown(cached);
    }
    final filters = {for (final server in servers) server.id: BooruBlacklist(blacklist(server.id))};
    final safebooru = {
      for (final server in servers)
        if (server.isSafebooru) server.id,
    };
    final lowered = query.toLowerCase();
    final shownFolders = folderID == null ? visibleFolders().map((folder) => folder.id).toSet() : null;
    final value =
        [
          for (final record in favoriteRecords())
            if ((folderID == null ? shownFolders!.contains(record.folderID) : record.folderID == folderID) && filters.containsKey(record.post.serverID))
              record.post,
        ].where((post) {
          if (filters[post.serverID]?.contains(post) ?? false) return false;
          if (safe && !safebooru.contains(post.serverID)) return false;
          return matches(post, query, lowered: lowered);
        }).toList();
    if (_visibleFavoritesRevision != version || _visibleFavoritesCache.length >= 32) {
      _visibleFavoritesCache.clear();
      _visibleFavoritesRevision = version;
    }
    _visibleFavoritesCache[key] = value;
    return shown(value);
  }

  Map<String, double> favoriteSavedDates() => {for (final record in favoriteRecords()) record.post.id: record.savedAt};

  /// Every folder of every server, global ones included.
  List<BooruFolder> folders() {
    final version = _snapshotVersion, cached = _cachedFolders;
    if (cached != null && cached.$1 == version) return cached.$2;
    final value = database.read((db) {
      final smart = BooruStoreFolderRules.fetchFolderRules(db).where((rule) => rule.isActive).map((rule) => rule.folder).toSet();
      return [
        for (final row in db.rows('SELECT * FROM folders ORDER BY position, name'))
          BooruFolder(
            id: row['id'] as String,
            name: row['name'] as String,
            color: row['color'] as int,
            isSmart: smart.contains(row['id']),
            serverID: row['server_id'] as String?,
          ),
      ];
    });
    _cachedFolders = (version, value);
    return value;
  }

  /// The folders Saved shows: the chosen servers' and the global ones.
  List<BooruFolder> visibleFolders() {
    final chosen = selectedServerIDs.toSet();
    return [
      for (final folder in folders())
        if (folder.serverID == null || chosen.contains(folder.serverID)) folder,
    ];
  }

  /// The folders an image of the server may go to: its own and the global ones.
  List<BooruFolder> foldersForServer(String serverID) => [
    for (final folder in folders())
      if (folder.holds(serverID)) folder,
  ];

  BooruFolder? folder(String id) => folders().where((folder) => folder.id == id).firstOrNull;

  /// The server a folder belongs to, by name, for when several servers' folders are shown together.
  String? serverNameOfFolder(BooruFolder folder) =>
      folder.serverID == null ? null : servers.where((server) => server.id == folder.serverID).firstOrNull?.displayName;

  /// Several servers' folders may share a name, so each is named with its server when more than one is set up.
  String labeledName(BooruFolder folder) {
    final server = servers.length > 1 ? serverNameOfFolder(folder) : null;
    return server == null ? folder.displayName : '${folder.displayName} · $server';
  }

  /// Creates a folder in a server, or a global one when [serverID] is null; for a folder that
  /// exists, only its name and color change.
  String saveFolder({String? id, required String name, int? color, String? serverID}) {
    final folderID = id ?? uuidString();
    final trimmedName = name.trim();
    if (trimmedName.isEmpty || folderID == 'unsorted') throw const BooruError(BooruErrorKind.invalidResponse);
    database.write((db) {
      final existing = db.row('SELECT color, server_id FROM folders WHERE id = ?', [folderID]);
      final owner = existing == null ? serverID : existing['server_id'] as String?;
      final resolved = color ?? existing?['color'] as int? ?? nextFolderColor(owner, db);
      db.execute(
        'INSERT INTO folders (id, name, color, position, server_id) VALUES (?, ?, ?, (SELECT COUNT(*) FROM folders), ?) ON CONFLICT(id) DO UPDATE SET name = excluded.name, color = excluded.color',
        [folderID, trimmedName, resolved, owner],
      );
    });
    revision += 1;
    return folderID;
  }

  /// A global folder is shown whichever servers are chosen and takes images of any of them. Made
  /// a server's folder again, it stays in each server it holds images of, with the same name and
  /// color; a global folder holding nothing goes to [emptyServer].
  void setGlobal(String id, bool global, {String? emptyServer}) {
    if (BooruFolder.isUncategorizedID(id)) return;
    database.write((db) {
      if (global) {
        db.execute('UPDATE folders SET server_id = NULL WHERE id = ?', [id]);
        return;
      }
      final addresses = {for (final server in _fetchServers(db)) server.id: server.canonicalAddress};
      final owners = db.column<String>('SELECT DISTINCT server_id FROM favorites WHERE folder_id = ?', [id]).where(addresses.containsKey).toList()
        ..sort((a, b) => addresses[a]!.compareTo(addresses[b]!));
      final owner = owners.firstOrNull ?? (emptyServer != null && addresses.containsKey(emptyServer) ? emptyServer : null);
      if (owner == null) return;
      db.execute('UPDATE folders SET server_id = ? WHERE id = ?', [owner, id]);
      settleFolders(db);
    });
    refresh();
  }

  /// A server's Uncategorized stays while the server does. Images of a deleted folder go where
  /// their server saves by default, or to its Uncategorized when that was this folder.
  void deleteFolder(String id) {
    database.write((db) {
      final owner = db.value<String>('SELECT server_id FROM folders WHERE id = ?', [id]);
      if (BooruFolder.isUncategorizedID(id) && owner != null && _server(owner, db) != null) throw const FolderDeletionError();
      moveImagesOutOf(id, db);
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
      // Another server's folder never takes it; global folders take any image.
      if (!folderHolds(target, post.serverID, db)) throw const BooruError(BooruErrorKind.invalidResponse);
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
    _warmSavedPreview(post);
  }

  void organizeLegacyImports() => database.write(organizeLegacyImportsIn);

  /// Repair the former shared import destination without moving user-created folders.
  static void organizeLegacyImportsIn(SqlDatabase db, {bool legacy = false}) {
    for (final serverID in db.column<String>("SELECT DISTINCT server_id FROM favorites WHERE folder_id = 'anime-boxes'")) {
      final folder = legacy ? _legacySiteFolder(serverID, db) : defaultFolder(serverID, db);
      db.execute("UPDATE favorites SET folder_id = ? WHERE server_id = ? AND folder_id = 'anime-boxes'", [folder, serverID]);
    }
    db.execute("DELETE FROM folders WHERE id = 'anime-boxes' AND NOT EXISTS (SELECT 1 FROM favorites WHERE folder_id = 'anime-boxes')");
  }

  /// The server's own folder as the migrations before folder ownership made it.
  static String _legacySiteFolder(String serverID, SqlDatabase db) {
    final data = db.value<Uint8List>('SELECT payload FROM servers WHERE id = ?', [serverID]);
    if (data == null) throw const BooruError(BooruErrorKind.invalidServer);
    final server = _decodeServer(data);
    final id = BooruFolder.uncategorizedPrefix + server.canonicalAddress;
    if (db.value<String>('SELECT id FROM folders WHERE id = ?', [id]) == null) {
      final color = AppDatabase.nextFolderColor(existingColors: db.column<int>('SELECT color FROM folders'));
      db.execute('INSERT INTO folders (id, name, color, position) VALUES (?, ?, ?, (SELECT COUNT(*) FROM folders))', [id, server.displayName, color]);
    }
    return id;
  }

  /// Where an image of the server is saved when no folder is chosen: the server's chosen folder,
  /// or its Uncategorized.
  static String defaultFolder(String serverID, SqlDatabase db) {
    final server = _server(serverID, db);
    if (server == null) throw const BooruError(BooruErrorKind.invalidServer);
    final chosen = server.saveFolder;
    if (chosen != null && folderHolds(chosen, serverID, db)) return chosen;
    return uncategorized(serverID, db);
  }

  // Folders by server

  /// A copy of a folder for another server is named `<folder>@<server address>`, the same on every
  /// device, so devices that split a folder at once agree on the copies.
  static const copyMarker = '@https://';
  static String copyID(String id, String address) => '${baseFolderID(id)}@$address';
  static String baseFolderID(String id) => id.split(copyMarker).first;

  static BooruServer? _server(String id, SqlDatabase db) {
    final data = db.value<Uint8List>('SELECT payload FROM servers WHERE id = ?', [id]);
    return data == null ? null : _decodeServer(data);
  }

  static List<BooruServer> decodedServers(SqlDatabase db) {
    final result = <BooruServer>[];
    for (final row in db.rows('SELECT payload FROM servers ORDER BY position')) {
      try {
        result.add(_decodeServer(row['payload']));
      } on Object {
        continue;
      }
    }
    return result;
  }

  /// Whether an image of the server may sit in the folder: one of the server's own, or a global one.
  static bool folderHolds(String id, String serverID, SqlDatabase db) {
    if (id == 'unsorted') return false;
    final row = db.row('SELECT server_id FROM folders WHERE id = ?', [id]);
    if (row == null) return false;
    final owner = row['server_id'] as String?;
    return owner == null || owner == serverID;
  }

  /// A color none of the folders shown beside it uses yet: the server's own and the global ones.
  static int nextFolderColor(String? serverID, SqlDatabase db) => AppDatabase.nextFolderColor(
    existingColors: serverID == null
        ? db.column<int>('SELECT color FROM folders')
        : db.column<int>('SELECT color FROM folders WHERE server_id = ? OR server_id IS NULL', [serverID]),
  );

  /// The server's Uncategorized, made when missing. It keeps the id the server's own folder had,
  /// so images already there stay.
  static String uncategorized(String serverID, SqlDatabase db) {
    final existing = db.value<String>('SELECT id FROM folders WHERE server_id = ? AND id GLOB ? ORDER BY position LIMIT 1', [
      serverID,
      '${BooruFolder.uncategorizedPrefix}*',
    ]);
    if (existing != null) return existing;
    final server = _server(serverID, db);
    if (server == null) throw const BooruError(BooruErrorKind.invalidServer);
    final id = BooruFolder.uncategorizedPrefix + server.canonicalAddress;
    if (db.value<String>('SELECT id FROM folders WHERE id = ?', [id]) != null) {
      // Left by another device, an older version or a server at this address before.
      db.execute('UPDATE folders SET server_id = ? WHERE id = ?', [serverID, id]);
    } else {
      // Named for the server, which is what versions before folder ownership show.
      db.execute('INSERT INTO folders (id, name, color, position, server_id) VALUES (?, ?, ?, (SELECT COUNT(*) FROM folders), ?)', [
        id,
        server.displayName,
        nextFolderColor(serverID, db),
        serverID,
      ]);
    }
    return id;
  }

  /// Before a folder goes: its images go where their server saves by default, or to the server's
  /// Uncategorized when that was this folder.
  static void moveImagesOutOf(String id, SqlDatabase db) {
    for (final serverID in db.column<String>('SELECT DISTINCT server_id FROM favorites WHERE folder_id = ?', [id])) {
      if (_server(serverID, db) == null) continue;
      var target = defaultFolder(serverID, db);
      if (target == id) target = uncategorized(serverID, db);
      db.execute('UPDATE favorites SET folder_id = ? WHERE folder_id = ? AND server_id = ?', [target, id, serverID]);
    }
  }

  /// The folder of the server that stands for the given one: the folder itself when it may hold
  /// the server's images, else the server's copy of it with its name, color, place and rule,
  /// made when missing.
  static String counterpart(String id, String serverID, SqlDatabase db) {
    if (folderHolds(id, serverID, db)) return id;
    if (BooruFolder.isUncategorizedID(id)) return uncategorized(serverID, db);
    final row = db.row('SELECT * FROM folders WHERE id = ?', [id]);
    final server = _server(serverID, db);
    if (row == null || server == null) return defaultFolder(serverID, db);
    final base = baseFolderID(id);
    if (base != id && db.value<String>('SELECT server_id FROM folders WHERE id = ?', [base]) == serverID) return base;
    final copy = copyID(id, server.canonicalAddress);
    final owner = db.row('SELECT server_id FROM folders WHERE id = ?', [copy]);
    if (owner != null) {
      if (owner['server_id'] != serverID) db.execute('UPDATE folders SET server_id = ? WHERE id = ?', [serverID, copy]);
      return copy;
    }
    db.execute('INSERT INTO folders (id, name, color, position, server_id) VALUES (?, ?, ?, ?, ?)', [
      copy,
      row['name'],
      row['color'],
      row['position'],
      serverID,
    ]);
    final rule = BooruStoreFolderRules.fetchFolderRules(db).where((rule) => rule.folder == id).firstOrNull;
    if (rule != null) {
      final sources = rule.sources;
      BooruStoreFolderRules.storeFolderRule(_copiedRule(rule, folder: copy, sources: sources == null ? null : _resolvedSources(sources, serverID, db)), db);
    }
    return copy;
  }

  static FolderRule _copiedRule(FolderRule rule, {String? folder, List<String>? sources}) => FolderRule(
    folder: folder ?? rule.folder,
    query: rule.query,
    excluded: rule.excluded,
    isEnabled: rule.isEnabled,
    sources: sources ?? rule.sources,
    includesOtherFolders: rule.includesOtherFolders,
    keepsOriginal: rule.keepsOriginal,
  );

  /// A rule's folders as the server's own: each of its folders that may hold the server's images,
  /// its copy for the server, or the server's Uncategorized for another server's.
  static List<String> _resolvedSources(List<String> sources, String serverID, SqlDatabase db) {
    final result = <String>[];
    final server = _server(serverID, db);
    for (final source in sources) {
      if (folderHolds(source, serverID, db)) {
        result.add(source);
      } else if (BooruFolder.isUncategorizedID(source)) {
        result.add(uncategorized(serverID, db));
      } else if (server != null && db.value<String>('SELECT id FROM folders WHERE id = ?', [copyID(source, server.canonicalAddress)]) != null) {
        result.add(copyID(source, server.canonicalAddress));
      }
    }
    final seen = <String>{};
    return result.where(seen.add).toList();
  }

  /// Gives every folder from before folder ownership a server: each server's own folder becomes
  /// its Uncategorized, a folder belongs to the server of its images (one folder of the same name
  /// in each when it holds several servers'), and a folder holding nothing stays global.
  /// [only] limits it to folders just restored from an older backup.
  static void assignFolderServers(SqlDatabase db, {Set<String>? only}) {
    final servers = decodedServers(db);
    final byAddress = <String, String>{};
    final addresses = <String, String>{};
    for (final server in servers) {
      byAddress.putIfAbsent(server.canonicalAddress, () => server.id);
      addresses.putIfAbsent(server.id, () => server.canonicalAddress);
    }
    for (final id in db.column<String>('SELECT id FROM folders ORDER BY position, name')) {
      if (id == 'unsorted' || !(only?.contains(id) ?? true)) continue;
      final owner = id.startsWith(BooruFolder.uncategorizedPrefix) ? byAddress[id.substring(BooruFolder.uncategorizedPrefix.length)] : null;
      if (owner != null) {
        db.execute('UPDATE folders SET server_id = ? WHERE id = ?', [owner, id]);
        continue;
      }
      // The server whose address comes first keeps the folder, so every device picks the same one.
      final owners = db.column<String>('SELECT DISTINCT server_id FROM favorites WHERE folder_id = ?', [id]).where(addresses.containsKey).toList()
        ..sort((a, b) => addresses[a]!.compareTo(addresses[b]!));
      if (owners.isNotEmpty) db.execute('UPDATE folders SET server_id = ? WHERE id = ?', [owners.first, id]);
    }
    settleFolders(db);
    // A rule reads its own server's folders; a global one reads every server's Uncategorized
    // where it read the shared one.
    final uncategorizedIDs = db.column<String>('SELECT id FROM folders WHERE id GLOB ?', ['${BooruFolder.uncategorizedPrefix}*']);
    for (final rule in BooruStoreFolderRules.fetchFolderRules(db)) {
      final sources = rule.sources;
      if (sources == null || !(only?.contains(rule.folder) ?? true)) continue;
      final row = db.row('SELECT server_id FROM folders WHERE id = ?', [rule.folder]);
      if (row == null) continue;
      final owner = row['server_id'] as String?;
      final resolved = owner != null
          ? _resolvedSources(sources, owner, db)
          : [
              for (final source in sources) ...(source == 'unsorted' ? uncategorizedIDs : [source]),
            ];
      BooruStoreFolderRules.storeFolderRule(_copiedRule(rule, sources: resolved), db);
    }
  }

  /// Puts every image where it may be: in a folder of its own server or a global one. Run after
  /// anything that brings folders or images from elsewhere: iCloud, a backup, an import, or an
  /// older version on another device. Each server keeps its Uncategorized.
  static void settleFolders(SqlDatabase db) {
    final servers = decodedServers(db);
    final known = {for (final server in servers) server.id};
    for (final server in servers) {
      uncategorized(server.id, db);
    }
    // Folders of servers that are gone, and the shared Uncategorized from before: their images
    // go to their own servers' folders of the same name.
    final stale = db.column<String>(
      "SELECT id FROM folders WHERE id = 'unsorted' OR (server_id IS NULL AND id GLOB ?) OR (server_id IS NOT NULL AND server_id NOT IN (SELECT id FROM servers))",
      ['${BooruFolder.uncategorizedPrefix}*'],
    );
    for (final id in stale) {
      for (final row in db.rows('SELECT server_id, post_id FROM favorites WHERE folder_id = ?', [id])) {
        final serverID = row['server_id'] as String;
        if (!known.contains(serverID)) continue;
        final target = BooruFolder.isUncategorizedID(id) ? uncategorized(serverID, db) : counterpart(id, serverID, db);
        db.execute('UPDATE favorites SET folder_id = ? WHERE server_id = ? AND post_id = ?', [target, serverID, row['post_id']]);
      }
      if (id == 'unsorted') {
        final rule = BooruStoreFolderRules.fetchFolderRules(db).where((rule) => rule.folder == id).firstOrNull;
        if (rule != null) {
          final ruled = BooruStoreFolderRules.fetchFolderRules(db).map((rule) => rule.folder).toSet();
          for (final server in servers) {
            final target = uncategorized(server.id, db);
            if (ruled.contains(target)) continue;
            final sources = rule.sources;
            BooruStoreFolderRules.storeFolderRule(
              _copiedRule(rule, folder: target, sources: sources == null ? null : _resolvedSources(sources, server.id, db)),
              db,
            );
          }
        }
      }
      db.execute('DELETE FROM folders WHERE id = ?', [id]);
      db.execute('DELETE FROM settings WHERE key = ?', [FolderRule.keyPrefix + id]);
    }
    // Images in a folder gone, or in another server's folder.
    final misplaced = db.rows(
      'SELECT f.server_id, f.post_id, f.folder_id FROM favorites f LEFT JOIN folders d ON d.id = f.folder_id '
      'WHERE d.id IS NULL OR (d.server_id IS NOT NULL AND d.server_id != f.server_id)',
    );
    for (final row in misplaced) {
      final serverID = row['server_id'] as String, folderID = row['folder_id'] as String;
      if (!known.contains(serverID)) continue;
      final exists = db.value<String>('SELECT id FROM folders WHERE id = ?', [folderID]) != null;
      final target = exists ? counterpart(folderID, serverID, db) : defaultFolder(serverID, db);
      db.execute('UPDATE favorites SET folder_id = ? WHERE server_id = ? AND post_id = ?', [target, serverID, row['post_id']]);
    }
    // Two devices may each have kept a different server's folder under the first id; a copy
    // that ended up in the same server as its original goes back into it.
    for (final row in db.rows('SELECT id, server_id FROM folders WHERE server_id IS NOT NULL AND instr(id, ?) > 0', [copyMarker])) {
      final id = row['id'] as String, owner = row['server_id'] as String, base = baseFolderID(id);
      if (db.value<String>('SELECT server_id FROM folders WHERE id = ?', [base]) != owner) continue;
      db.execute('UPDATE favorites SET folder_id = ? WHERE folder_id = ?', [base, id]);
      db.execute('DELETE FROM folders WHERE id = ?', [id]);
      db.execute('DELETE FROM settings WHERE key = ?', [FolderRule.keyPrefix + id]);
    }
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
    if (value.isEmpty || PrivacySettings.isIncognito) return;
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

  // MARK: - Taste (TasteLibraryIntegration.swift)

  void observeTaste(BooruPost post, DiscoveryContext context) =>
      database.write((db) => TasteStore.record(TasteEventKind.open, tasteItem(post, db), db, context: context));

  void recordTasteSearch(DiscoveryContext context, List<BooruServer> servers) {
    if (context.origin != DiscoveryOrigin.search || context.included.isEmpty) return;
    database.write((db) {
      for (final server in servers) {
        TasteStore.record(
          TasteEventKind.search,
          TasteItem(source: server.canonicalAddress, id: 0, tags: context.included.toList()),
          db,
          context: context,
        );
      }
    });
  }

  void recordDwell(TasteDwell dwell, BooruPost post, DiscoveryContext context) =>
      database.write((db) => TasteStore.recordDwell(dwell, tasteItem(post, db), context, db));

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

  /// Moves the images the folder may hold: any into a global folder, a server's own into its folders.
  void moveFavorites(List<BooruPost> posts, String folderID) {
    database.write((db) {
      if (!db.exists('SELECT EXISTS(SELECT 1 FROM folders WHERE id = ?)', [folderID])) throw const BooruError(BooruErrorKind.invalidResponse);
      for (final post in posts) {
        if (!folderHolds(folderID, post.serverID, db)) continue;
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
  int matchingCountElsewhere(FolderRule rule) => matchingRuleCountElsewhere(rule);
  @override
  String createRuleFolder(String named) => saveFolder(name: named);
  @override
  void saveRule(FolderRule rule) => saveFolderRule(rule);
  @override
  void deleteRule(String forFolder) => deleteFolderRule(forFolder);
  @override
  void fill(FolderRule rule) => fillRule(rule);
}
