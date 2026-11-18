import 'dart:io';
import 'dart:typed_data';

import 'package:characters/characters.dart';

import '../../domain/models.dart';
import '../storage/app_database.dart';
import '../storage/folder_rules.dart';
import '../study/study_models.dart';
import '../support/sql_database.dart';
import '../content/recent_works.dart';
import '../support/swift_json.dart';
import '../support/swift_url.dart';
import '../taste/taste_models.dart';
import '../taste/taste_store.dart';
import 'booru_models.dart';
import 'booru_store.dart';
import '../storage/folder_palette.dart';

/// [serverID] names one of the backup's servers; [isGlobal] marks a folder of every server. Both
/// absent, it is from before folders belonged to servers, and goes where its images are.
class BooruBackupFolder {
  BooruBackupFolder({required this.id, required this.name, required this.color, this.serverID, this.isGlobal});
  final String id;
  final String name;
  final int color;
  final String? serverID;
  final bool? isGlobal;
  bool get isLegacy => serverID == null && isGlobal == null;

  factory BooruBackupFolder.fromJson(JsonObject json) => BooruBackupFolder(
    id: json.string('id'),
    name: json.string('name'),
    color: json.integer('color'),
    serverID: json.stringOrNull('serverID'),
    isGlobal: json['isGlobal'] as bool?,
  );
  JsonObject toJson() => {'id': id, 'name': name, 'color': color, 'serverID': ?serverID, 'isGlobal': ?isGlobal};
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

/// A recently opened image; `openedAt` is seconds since 1970, as both apps write it.
class BooruBackupRecent {
  BooruBackupRecent({required this.post, required this.openedAt});
  BooruPost post;
  double openedAt;
  factory BooruBackupRecent.fromJson(JsonObject json) => BooruBackupRecent(post: BooruPost.fromJson(json.object('post')), openedAt: json.number('openedAt'));
  JsonObject toJson() => {'post': post.toJson(), 'openedAt': openedAt};
}

/// One tag's study progress; times are seconds since 1970, as both apps write them.
class BooruBackupLearned {
  BooruBackupLearned({required this.tag, required this.step, required this.due, required this.correct, required this.wrong, required this.seen});
  final String tag;
  final int step;
  final double due;
  final int correct;
  final int wrong;
  final double seen;

  factory BooruBackupLearned.fromJson(JsonObject json) => BooruBackupLearned(
    tag: json.string('tag'),
    step: json.integer('step'),
    due: json.number('due'),
    correct: json.integer('correct'),
    wrong: json.integer('wrong'),
    seen: json.number('seen'),
  );
  JsonObject toJson() => {'tag': tag, 'step': step, 'due': due, 'correct': correct, 'wrong': wrong, 'seen': seen};
}

/// Tag study: what has been learned and each day's answers.
class BooruBackupStudy {
  BooruBackupStudy({required this.progress, required this.days});
  final List<BooruBackupLearned> progress;
  final List<StudyDay> days;

  factory BooruBackupStudy.fromJson(JsonObject json) => BooruBackupStudy(
    progress: json.list('progress', (value) => BooruBackupLearned.fromJson(jsonObject(value))),
    days: json.list('days', (value) => StudyDay.fromJson(jsonObject(value))),
  );
  JsonObject toJson() => {
    'progress': [for (final value in progress) value.toJson()],
    'days': [for (final day in days) day.toJson()],
  };

  bool get isValid =>
      progress.every(
        (value) =>
            value.tag.isNotEmpty &&
            value.tag.characters.length <= 200 &&
            value.step >= 0 &&
            value.step <= StudyProgress.lastStep &&
            value.correct >= 0 &&
            value.wrong >= 0 &&
            value.due.isFinite &&
            value.seen.isFinite,
      ) &&
      days.every((day) => day.day.characters.length == 10 && day.answered >= 0 && day.correct >= 0 && day.correct <= day.answered);
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
    this.recentImages,
    this.study,
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

  /// Optional so backups from before recent images still read.
  List<BooruBackupRecent>? recentImages;

  /// Tag study progress. Optional so backups from before tag study still read.
  BooruBackupStudy? study;

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
    recentImages: json.listOrNull('recentImages', (value) => BooruBackupRecent.fromJson(jsonObject(value))),
    study: json.objectOrNull('study') == null ? null : BooruBackupStudy.fromJson(json.object('study')),
  );

  JsonObject toJson() =>
      <String, Object?>{
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
        }
        ..putIfPresent('folderRules', folderRules == null ? null : [for (final rule in folderRules!) rule.toJson()])
        ..putIfPresent('recentImages', recentImages == null ? null : [for (final recent in recentImages!) recent.toJson()])
        ..putIfPresent('study', study?.toJson());

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
        folders.every((folder) => folder.serverID == null || serverIDs.contains(folder.serverID)) &&
        serverIDs.containsAll(selectedServerIDs) &&
        (folderRules ?? []).every((rule) => folderIDs.contains(rule.folder) && rule.query.isNotEmpty) &&
        (recentImages ?? []).every((recent) => serverIDs.contains(recent.post.serverID) && recent.post.postID > 0 && recent.openedAt.isFinite) &&
        (study?.isValid ?? true);
    if (!valid) throw const BooruError(BooruErrorKind.invalidResponse);
    for (final post in [for (final favorite in favorites) favorite.post, for (final recent in recentImages ?? const <BooruBackupRecent>[]) recent.post]) {
      for (final url in [post.previewURL, post.sampleURL, post.fileURL, post.animationVideoURL].nonNulls) {
        if (!isRemoteURL(url, allowCredentials: false)) throw const BooruError(BooruErrorKind.invalidResponse);
      }
    }
  }

  Uint8List encoded() => encodeJson(toJson(), pretty: true);

  /// Recent images placed on this device's servers, matched by address as a restore matches them.
  List<RecentImage> recentImagesOn(List<BooruServer> current) {
    final addresses = {for (final server in servers) server.id: server.canonicalAddress};
    return [
      for (final recent in recentImages ?? const <BooruBackupRecent>[])
        if (current.where((server) => server.canonicalAddress == addresses[recent.post.serverID]).firstOrNull case final server?)
          RecentImage(post: recent.post.onServer(server.id), openedAt: DateTime.fromMillisecondsSinceEpoch((recent.openedAt * 1000).round())),
    ];
  }
}

extension BooruStoreBackup on BooruStore {
  BooruBackup exportBackup() => database.read((db) {
    final servers = db
        .rows('SELECT payload FROM servers ORDER BY position')
        .map((row) => BooruServer.fromJson(decodeJsonObject(row['payload'] as Uint8List)))
        .toList();
    final folders = [
      for (final row in db.rows('SELECT * FROM folders ORDER BY position, name'))
        BooruBackupFolder(
          id: row['id'] as String,
          name: row['name'] as String,
          color: row['color'] as int,
          serverID: row['server_id'] as String?,
          isGlobal: row['server_id'] == null,
        ),
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
    final learned = [
      for (final row in db.rows('SELECT * FROM study_progress ORDER BY tag'))
        BooruBackupLearned(
          tag: row['tag'] as String,
          step: row['step'] as int,
          due: (row['due'] as num).toDouble(),
          correct: row['correct'] as int,
          wrong: row['wrong'] as int,
          seen: (row['seen'] as num).toDouble(),
        ),
    ];
    final days = [
      for (final row in db.rows('SELECT * FROM study_days ORDER BY day'))
        StudyDay(day: row['day'] as String, answered: row['answered'] as int, correct: row['correct'] as int),
    ];
    return BooruBackup(
      servers: servers,
      folders: folders,
      favorites: favorites,
      history: history,
      savedTags: tags,
      blacklist: blacklist,
      selectedServerIDs: selectedServerIDs,
      folderRules: BooruStoreFolderRules.fetchFolderRules(db).where((rule) => folders.any((folder) => folder.id == rule.folder)).toList(),
      study: learned.isEmpty && days.isEmpty ? null : BooruBackupStudy(progress: learned, days: days),
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
      final owner = folder.isGlobal == true || folder.serverID == null ? null : mapping[folder.serverID];
      // A folder from before folders belonged to servers keeps the server it has here.
      db.execute(
        'INSERT INTO folders (id, name, color, position, server_id) VALUES (?, ?, ?, ?, ?) ON CONFLICT(id) DO UPDATE SET name = excluded.name, color = excluded.color, position = excluded.position${folder.isLegacy ? '' : ', server_id = excluded.server_id'}',
        [folder.id, folder.id == 'unsorted' ? '' : folder.name, FolderPalette.vivid(folder.color), position, owner],
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
    // Study progress merges: a tag keeps whichever answer came later, and a day its larger count.
    for (final value in backup.study?.progress ?? const <BooruBackupLearned>[]) {
      db.execute(
        '''
        INSERT INTO study_progress (tag, step, due, correct, wrong, seen) VALUES (?, ?, ?, ?, ?, ?)
        ON CONFLICT(tag) DO UPDATE SET step = excluded.step, due = excluded.due, correct = excluded.correct, wrong = excluded.wrong, seen = excluded.seen
        WHERE excluded.seen > study_progress.seen
        ''',
        [value.tag, value.step, value.due, value.correct, value.wrong, value.seen],
      );
    }
    for (final value in backup.study?.days ?? const <StudyDay>[]) {
      db.execute(
        '''
        INSERT INTO study_days (day, answered, correct) VALUES (?, ?, ?)
        ON CONFLICT(day) DO UPDATE SET answered = MAX(answered, excluded.answered), correct = MAX(correct, excluded.correct)
        ''',
        [value.day, value.answered, value.correct],
      );
    }
    // Folders of an older backup go where their images are, and every image to a folder of its server.
    BooruStore.assignFolderServers(
      db,
      only: {
        for (final folder in backup.folders)
          if (folder.isLegacy) folder.id,
      },
    );
    // The order kept is the one the folders now have, each server's Uncategorized included, so a
    // second restore of the same backup changes nothing.
    db.execute("INSERT OR REPLACE INTO settings VALUES ('folder_order', ?)", [
      encodeSwiftJsonString(db.column<String>('SELECT id FROM folders ORDER BY position, name')),
    ]);
    if (backup.selectedServerIDs.isNotEmpty) {
      db.execute("INSERT OR REPLACE INTO settings VALUES ('selected_servers', ?)", [
        encodeSwiftJsonString(backup.selectedServerIDs.map((id) => mapping[id]).nonNulls.toList()),
      ]);
    }
  }
}
