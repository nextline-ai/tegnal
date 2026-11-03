import 'dart:io';
import 'dart:typed_data';

import '../../domain/models.dart';
import '../storage/app_database.dart';
import '../storage/folder_rules.dart';
import '../support/sql_database.dart';
import '../support/swift_json.dart';
import '../support/swift_url.dart';
import '../taste/taste_models.dart';
import '../taste/taste_store.dart';
import 'booru_models.dart';
import 'booru_store.dart';

class BooruBackupFolder {
  BooruBackupFolder({required this.id, required this.name, required this.color});
  final String id;
  final String name;
  final int color;

  factory BooruBackupFolder.fromJson(JsonObject json) => BooruBackupFolder(id: json.string('id'), name: json.string('name'), color: json.integer('color'));
  JsonObject toJson() => {'id': id, 'name': name, 'color': color};
}

class BooruBackupFavorite {
  BooruBackupFavorite({required this.post, required this.folderID, required this.savedAt});
  BooruPost post;
  final String folderID;
  final double savedAt;

  factory BooruBackupFavorite.fromJson(JsonObject json) =>
      BooruBackupFavorite(post: BooruPost.fromJson(json.object('post')), folderID: json.string('folderID'), savedAt: json.number('savedAt'));
  JsonObject toJson() => {'post': post.toJson(), 'folderID': folderID, 'savedAt': savedAt};
}

class BooruBackupSearch {
  BooruBackupSearch({required this.serverID, required this.query, required this.usedAt});
  final String serverID;
  final String query;
  final double usedAt;

  factory BooruBackupSearch.fromJson(JsonObject json) =>
      BooruBackupSearch(serverID: json.string('serverID'), query: json.string('query'), usedAt: json.number('usedAt'));
  JsonObject toJson() => {'serverID': serverID, 'query': query, 'usedAt': usedAt};
}

class BooruBackupTag {
  BooruBackupTag({required this.serverID, required this.name, required this.kind});
  final String serverID;
  final String name;
  final String kind;

  factory BooruBackupTag.fromJson(JsonObject json) => BooruBackupTag(serverID: json.string('serverID'), name: json.string('name'), kind: json.string('kind'));
  JsonObject toJson() => {'serverID': serverID, 'name': name, 'kind': kind};
}

/// Portable library data only. Credentials, cookies, caches and device preferences stay local.
class BooruBackup {
  BooruBackup({
    this.format = 'tegnal-image-library',
    this.version = 1,
    DateTime? exportedAt,
    required this.servers,
    required this.folders,
    required this.favorites,
    required this.history,
    required this.savedTags,
    required this.blacklist,
    required this.selectedServerIDs,
    this.folderRules,
  }) : exportedAt = exportedAt ?? DateTime.now();

  String format;
  int version;
  DateTime exportedAt;
  List<BooruServer> servers;
  List<BooruBackupFolder> folders;
  List<BooruBackupFavorite> favorites;
  List<BooruBackupSearch> history;
  List<BooruBackupTag> savedTags;
  Map<String, String> blacklist;
  List<String> selectedServerIDs;

  /// Optional so backups from before smart folders still read.
  List<FolderRule>? folderRules;

  static const maximumBytes = 64 * 1024 * 1024;

  factory BooruBackup.fromJson(JsonObject json) => BooruBackup(
    format: json.string('format'),
    version: json.integer('version'),
    // `Date` in Swift's default encoding: seconds since 2001-01-01.
    exportedAt: dateFromSwiftReferenceSeconds(json.number('exportedAt')),
    servers: json.list('servers', (value) => BooruServer.fromJson(jsonObject(value))),
    folders: json.list('folders', (value) => BooruBackupFolder.fromJson(jsonObject(value))),
    favorites: json.list('favorites', (value) => BooruBackupFavorite.fromJson(jsonObject(value))),
    history: json.list('history', (value) => BooruBackupSearch.fromJson(jsonObject(value))),
    savedTags: json.list('savedTags', (value) => BooruBackupTag.fromJson(jsonObject(value))),
    blacklist: json.dictionary('blacklist', jsonString),
    selectedServerIDs: json.strings('selectedServerIDs'),
    folderRules: json.listOrNull('folderRules', (value) => FolderRule.fromJson(jsonObject(value))),
  );

  JsonObject toJson() => <String, Object?>{
    'format': format,
    'version': version,
    'exportedAt': swiftReferenceSeconds(exportedAt),
    'servers': [for (final server in servers) server.toJson()],
    'folders': [for (final folder in folders) folder.toJson()],
    'favorites': [for (final favorite in favorites) favorite.toJson()],
    'history': [for (final search in history) search.toJson()],
    'savedTags': [for (final tag in savedTags) tag.toJson()],
    'blacklist': blacklist,
    'selectedServerIDs': selectedServerIDs,
  }..putIfPresent('folderRules', folderRules == null ? null : [for (final rule in folderRules!) rule.toJson()]);

  static BooruBackup read(File file) {
    if (file.lengthSync() > maximumBytes) throw const BooruError(BooruErrorKind.invalidResponse);
    return decode(file.readAsBytesSync());
  }

  static BooruBackup decode(List<int> data) {
    if (data.length > maximumBytes) throw const BooruError(BooruErrorKind.invalidResponse);
    final value = BooruBackup.fromJson(decodeJsonObject(data));
    // Only import recognizes the historical format; all new exports use TEGNAL.
    if (value.format == 'number-memo-image-library') value.format = 'tegnal-image-library';
    value.validate();
    return value;
  }

  void validate() {
    for (final server in servers) {
      BooruServer.validatedURL(server.baseURL);
    }
    final serverIDs = servers.map((server) => server.id).toSet(), folderIDs = folders.map((folder) => folder.id).toSet();
    final valid =
        format == 'tegnal-image-library' &&
        version == 1 &&
        serverIDs.length == servers.length &&
        folderIDs.length == folders.length &&
        servers.every((server) => server.id.isNotEmpty) &&
        folders.every(
          (folder) => folder.id.isNotEmpty && folder.color >= 0 && folder.color <= 0xFFFFFFFF && (folder.id == 'unsorted' || folder.name.trim().isNotEmpty),
        ) &&
        servers.map((server) => server.canonicalAddress).toSet().length == servers.length &&
        favorites.map((favorite) => favorite.post.id).toSet().length == favorites.length &&
        favorites.every(
          (favorite) =>
              serverIDs.contains(favorite.post.serverID) && folderIDs.contains(favorite.folderID) && favorite.post.postID > 0 && favorite.savedAt.isFinite,
        ) &&
        history.every((search) => serverIDs.contains(search.serverID) && search.query.isNotEmpty && search.usedAt.isFinite) &&
        savedTags.every((tag) {
          final kind = SavedCollectionKind.fromRawValue(tag.kind);
          return serverIDs.contains(tag.serverID) && tag.name.isNotEmpty && kind != null && kind != SavedCollectionKind.history;
        }) &&
        serverIDs.containsAll(blacklist.keys) &&
        serverIDs.containsAll(selectedServerIDs) &&
        (folderRules ?? []).every((rule) => folderIDs.contains(rule.folder) && rule.query.isNotEmpty);
    if (!valid) throw const BooruError(BooruErrorKind.invalidResponse);
    for (final favorite in favorites) {
      final post = favorite.post;
      for (final url in [post.previewURL, post.sampleURL, post.fileURL, post.animationVideoURL].nonNulls) {
        if (!isRemoteURL(url, allowCredentials: false)) throw const BooruError(BooruErrorKind.invalidResponse);
      }
    }
  }

  Uint8List encoded() => encodeJson(toJson(), pretty: true);
}

extension BooruStoreBackup on BooruStore {
  BooruBackup exportBackup() => database.read((db) {
    final servers = db
        .rows('SELECT payload FROM servers ORDER BY position')
        .map((row) => BooruServer.fromJson(decodeJsonObject(row['payload'] as Uint8List)))
        .toList();
    final folders = [
      for (final row in db.rows('SELECT * FROM folders ORDER BY position, name'))
        BooruBackupFolder(id: row['id'] as String, name: row['name'] as String, color: row['color'] as int),
    ];
    final favorites = [
      for (final row in db.rows('SELECT * FROM favorites ORDER BY saved_at DESC'))
        BooruBackupFavorite(
          post: BooruPost.fromJson(decodeJsonObject(row['payload'] as Uint8List)),
          folderID: row['folder_id'] as String,
          savedAt: (row['saved_at'] as num).toDouble(),
        ),
    ];
    final history = [
      for (final row in db.rows('SELECT * FROM history WHERE used_at >= ? ORDER BY used_at DESC', [SearchRetention.cutoff(preferences.booruDefaults)]))
        BooruBackupSearch(serverID: row['server_id'] as String, query: row['query'] as String, usedAt: (row['used_at'] as num).toDouble()),
    ];
    final tags = [
      for (final row in db.rows('SELECT * FROM saved_tags ORDER BY server_id, kind, name'))
        BooruBackupTag(serverID: row['server_id'] as String, name: row['name'] as String, kind: row['kind'] as String),
    ];
    final blacklist = {
      for (final server in servers) server.id: db.value<String>('SELECT value FROM settings WHERE key = ?', ['blacklist.${server.id}']) ?? '',
    };
    return BooruBackup(
      servers: servers,
      folders: folders,
      favorites: favorites,
      history: history,
      savedTags: tags,
      blacklist: blacklist,
      selectedServerIDs: selectedServerIDs,
      folderRules: BooruStoreFolderRules.fetchFolderRules(db).where((rule) => folders.any((folder) => folder.id == rule.folder)).toList(),
    );
  });

  /// Merge atomically; repeated imports never duplicate servers, folders or favorites.
  /// The backup restores colors, folder membership and ordering without deleting other items.
  void restoreBackup(BooruBackup backup) {
    backup.validate();
    database.write((db) => restoreBackupIn(backup, db));
    refresh();
  }

  /// Allows a combined restore to validate and write both libraries in one operation.
  void restoreBackupIn(BooruBackup backup, SqlDatabase db) {
    final existing = db
        .rows('SELECT payload FROM servers ORDER BY position')
        .map((row) => BooruServer.fromJson(decodeJsonObject(row['payload'] as Uint8List)))
        .toList();
    final mapping = <String, String>{};
    for (final source in backup.servers) {
      final match = existing.where((server) => server.canonicalAddress == source.canonicalAddress).firstOrNull;
      if (match != null) {
        mapping[source.id] = match.id;
      } else {
        final server = BooruServer(id: source.id, name: source.name, baseURL: source.baseURL, engine: source.engine);
        if (existing.any((other) => other.id == server.id)) server.id = uuidString();
        mapping[source.id] = server.id;
        db.execute('INSERT INTO servers VALUES (?, ?, (SELECT COUNT(*) FROM servers))', [server.id, encodeSwiftJson(server.toJson())]);
      }
    }
    final incomingOrder = backup.folders.map((folder) => folder.id).toList();
    final remaining = db.column<String>('SELECT id FROM folders ORDER BY position, name').where((id) => !incomingOrder.contains(id)).toList();
    for (final (position, folder) in backup.folders.indexed) {
      db.execute(
        'INSERT INTO folders VALUES (?, ?, ?, ?) ON CONFLICT(id) DO UPDATE SET name = excluded.name, color = excluded.color, position = excluded.position',
        [folder.id, folder.id == 'unsorted' ? '' : folder.name, folder.color, position],
      );
    }
    for (final (position, id) in [...incomingOrder, ...remaining].indexed) {
      db.execute('UPDATE folders SET position = ? WHERE id = ?', [position, id]);
    }
    db.execute("INSERT OR REPLACE INTO settings VALUES ('folder_order', ?)", [
      encodeSwiftJsonString([...incomingOrder, ...remaining]),
    ]);
    for (final value in backup.favorites) {
      final targetServerID = mapping[value.post.serverID];
      if (targetServerID == null) continue;
      final post = value.post.onServer(targetServerID);
      final existed = db.exists('SELECT EXISTS(SELECT 1 FROM favorites WHERE server_id = ? AND post_id = ?)', [post.serverID, post.postID]);
      db.execute(
        'INSERT INTO favorites VALUES (?, ?, ?, ?, ?) ON CONFLICT(server_id, post_id) DO UPDATE SET payload = excluded.payload, saved_at = excluded.saved_at, folder_id = excluded.folder_id',
        [post.serverID, post.postID, encodeSwiftJson(post.toJson()), value.savedAt, value.folderID],
      );
      TasteStore.record(existed ? TasteEventKind.metadata : TasteEventKind.imported, BooruStore.tasteItem(post, db), db);
    }
    for (final value in backup.history) {
      final targetServerID = mapping[value.serverID];
      if (targetServerID == null) continue;
      db.execute('INSERT INTO history VALUES (?, ?, ?) ON CONFLICT(server_id, query) DO UPDATE SET used_at = MAX(used_at, excluded.used_at)', [
        targetServerID,
        value.query,
        value.usedAt,
      ]);
    }
    for (final value in backup.savedTags) {
      final targetServerID = mapping[value.serverID];
      if (targetServerID == null) continue;
      db.execute('INSERT OR IGNORE INTO saved_tags VALUES (?, ?, ?)', [targetServerID, value.name, value.kind]);
    }
    for (final MapEntry(key: id, value: rules) in backup.blacklist.entries) {
      final targetServerID = mapping[id];
      if (targetServerID == null) continue;
      db.execute('INSERT OR REPLACE INTO settings VALUES (?, ?)', ['blacklist.$targetServerID', rules]);
    }
    for (final rule in backup.folderRules ?? <FolderRule>[]) {
      BooruStoreFolderRules.storeFolderRule(rule, db);
    }
    if (backup.selectedServerIDs.isNotEmpty) {
      db.execute("INSERT OR REPLACE INTO settings VALUES ('selected_servers', ?)", [
        encodeSwiftJsonString(backup.selectedServerIDs.map((id) => mapping[id]).nonNulls.toList()),
      ]);
    }
  }
}
