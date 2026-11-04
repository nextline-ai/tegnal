import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import '../storage/folder_rules.dart';
import '../support/l10n.dart';
import '../support/swift_json.dart';
import '../taste/taste_models.dart';
import '../taste/taste_store.dart';
import 'booru_models.dart';
import 'booru_store.dart';

enum AnimeBoxesImportError implements Exception {
  format,
  tooLarge,
  noServers;

  String get message => switch (this) {
    format => L10n.text('Choose an Anime Boxes .abbj backup (version 1.0).'),
    tooLarge => L10n.text('This backup exceeds the 64 MB import limit.'),
    noServers => L10n.text('This backup contains no supported servers.'),
  };

  @override
  String toString() => message;
}

class AnimeBoxesFavorite {
  const AnimeBoxesFavorite(this.post, this.savedAt);
  final BooruPost post;
  final double savedAt;
}

class AnimeBoxesSearch {
  const AnimeBoxesSearch({required this.text, required this.date, required this.starred});
  final String text;
  final double date;
  final bool starred;
}

/// An Anime Boxes `.abbj` backup, read without trusting its addresses: servers must be
/// valid HTTPS sites and media addresses are upgraded to HTTPS.
class AnimeBoxesBackup {
  const AnimeBoxesBackup({
    required this.servers,
    required this.selectedIDs,
    required this.favorites,
    required this.history,
    required this.blacklist,
    required this.skippedServers,
    required this.skippedFavorites,
    required this.skippedHistory,
    required this.skippedRules,
  });

  static const maximumBytes = 64 * 1024 * 1024;

  final List<BooruServer> servers;
  final List<String> selectedIDs;
  final List<AnimeBoxesFavorite> favorites;
  final List<AnimeBoxesSearch> history;
  final List<String> blacklist;
  final int skippedServers;
  final int skippedFavorites;
  final int skippedHistory;
  final int skippedRules;

  static AnimeBoxesBackup read(File file) {
    if (file.lengthSync() > maximumBytes) throw AnimeBoxesImportError.tooLarge;
    return parse(file.readAsBytesSync());
  }

  static AnimeBoxesBackup parse(Uint8List data) {
    if (data.length > maximumBytes) throw AnimeBoxesImportError.tooLarge;
    Object? root;
    try {
      root = jsonDecode(utf8.decode(data, allowMalformed: true));
    } on FormatException {
      throw AnimeBoxesImportError.format;
    }
    if (root is! Map || root['servers'] is! List || root['favorites'] is! List || root['backupVersion'] != '1.0') throw AnimeBoxesImportError.format;
    final servers = <BooruServer>[], selected = <String>[], favorites = <AnimeBoxesFavorite>[];
    var skippedServers = 0, skippedFavorites = 0;
    for (final row in (root['servers'] as List).whereType<Map>()) {
      final raw = row['url'];
      final url = _baseURL(raw is String ? raw : '');
      final host = url == null ? null : Uri.tryParse(url)?.host;
      if (url == null || host == null || host.isEmpty) {
        skippedServers += 1;
        continue;
      }
      // Engines are told apart by the backup's own type field, never by a site's name.
      final engine = switch (_integer(row['type'])) {
        1 => BooruEngine.gelbooru,
        4 => BooruEngine.oldGelbooru,
        3 => BooruEngine.danbooru,
        _ => null,
      };
      if (engine == null) {
        skippedServers += 1;
        continue;
      }
      final canonical = BooruServer.canonicalAddressOf(url);
      var server = servers.where((server) => server.canonicalAddress == canonical).firstOrNull;
      if (server == null) {
        final name = row['serverName'];
        server = BooruServer(name: name is String && name.isNotEmpty ? name : host, baseURL: url, engine: engine);
        servers.add(server);
      }
      if (row['isSelected'] == true) selected.add(server.id);
    }
    double date(Object? raw) => raw is String ? (DateTime.tryParse(raw)?.microsecondsSinceEpoch ?? 0) / 1e6 : 0;
    final seen = <String>{};
    for (final row in (root['favorites'] as List).whereType<Map>()) {
      final postID = _integer(row['ppostId']);
      final page = row['ppostUrl'] is String ? BooruServer.canonicalAddressOf(row['ppostUrl'] as String) : null;
      BooruServer? server;
      if (page != null) {
        for (final candidate in servers) {
          if (!(page.startsWith('${candidate.canonicalAddress}/') || page == candidate.canonicalAddress)) continue;
          if (server == null || (Uri.tryParse(candidate.baseURL)?.path.length ?? 0) > (Uri.tryParse(server.baseURL)?.path.length ?? 0)) server = candidate;
        }
      }
      if (postID == null || postID <= 0 || server == null) {
        skippedFavorites += 1;
        continue;
      }
      Map<Object?, Object?> object(String key) => row[key] is Map ? row[key] as Map : const {};
      final file = object('file');
      final fileURL = _mediaURL(file['url'], server.baseURL);
      final rating = row['rating'] is String ? row['rating'] as String : '';
      final extension = file['ext'] is String ? file['ext'] as String : (fileURL == null ? '' : urlPathExtension(fileURL));
      final post = BooruPost(
        serverID: server.id,
        postID: postID,
        previewURL: _mediaURL(object('preview')['url'], server.baseURL),
        sampleURL: _mediaURL(object('sample')['url'], server.baseURL) ?? _mediaURL(object('jpeg')['url'], server.baseURL),
        fileURL: fileURL,
        width: (_integer(file['width']) ?? 0).clamp(0, 1 << 31),
        height: (_integer(file['height']) ?? 0).clamp(0, 1 << 31),
        tags: _tokens(row['tags']),
        artists: _tokens(row['tag_artist']),
        rating: !server.usesModernRatings && rating == 's' ? 'g' : rating,
        score: _integer(row['score']) ?? 0,
        fileExtension: extension.toLowerCase(),
      );
      if (seen.add(post.id)) favorites.add(AnimeBoxesFavorite(post, date(row['dateAdded'])));
    }
    final rawHistory = root['searchHistory'] is List ? root['searchHistory'] as List : const [];
    final history = <AnimeBoxesSearch>[
      for (final row in rawHistory.whereType<Map>())
        if (row['searchText'] case final String text when text.trim().isNotEmpty)
          AnimeBoxesSearch(text: text, date: date(row['searchDate']), starred: row['starred'] == true),
    ];
    final rawRules = root['bannedTags'] is List ? root['bannedTags'] as List : const [];
    final blacklist = <String>[
      for (final rule in rawRules)
        if (rule is String && rule.isNotEmpty)
          rule
        else if (rule is Map)
          if (rule['tag'] ?? rule['name'] case final String value when value.isNotEmpty) value,
    ];
    return AnimeBoxesBackup(
      servers: servers,
      selectedIDs: selected,
      favorites: favorites,
      history: history,
      blacklist: blacklist,
      skippedServers: skippedServers,
      skippedFavorites: skippedFavorites,
      skippedHistory: rawHistory.length - history.length,
      skippedRules: rawRules.length - blacklist.length,
    );
  }

  static int? _integer(Object? value) => switch (value) {
    final int number => number,
    final double number => number.toInt(),
    final String text => int.tryParse(text),
    _ => null,
  };

  static List<String> _tokens(Object? value) {
    if (value is List) return value.whereType<String>().toList();
    return splitWhitespace(value is String ? value : '');
  }

  static String? _baseURL(String raw) {
    if (raw.isEmpty) return null;
    final secure = raw.startsWith('http://') ? 'https://${raw.substring(7)}' : raw;
    try {
      return BooruServer.validatedURL(secure);
    } on Object {
      return null;
    }
  }

  static String? _mediaURL(Object? raw, String base) {
    if (raw is! String || raw.isEmpty) return null;
    final Uri url;
    try {
      url = Uri.parse(base).resolve(raw);
    } on FormatException {
      return null;
    }
    if (!const {'https', 'http'}.contains(url.scheme) || url.host.isEmpty || url.userInfo.isNotEmpty) return null;
    return url.replace(scheme: 'https').toString();
  }
}

class AnimeBoxesImportOptions {
  const AnimeBoxesImportOptions({this.history = true, this.blacklist = true, this.selection = true, this.folderID = 'by-site'});
  final bool history;
  final bool blacklist;
  final bool selection;

  /// `by-site`, `anime-boxes`, or an existing folder's ID.
  final String folderID;
}

class AnimeBoxesImportResult {
  const AnimeBoxesImportResult({required this.added, required this.duplicates, required this.serversAdded});
  final int added;
  final int duplicates;
  final int serversAdded;
}

extension BooruStoreAnimeBoxes on BooruStore {
  /// The entire merge commits together. Existing favorites keep custom folders and their original saved date.
  AnimeBoxesImportResult importAnimeBoxes(AnimeBoxesBackup backup, {AnimeBoxesImportOptions options = const AnimeBoxesImportOptions()}) {
    if (backup.servers.isEmpty) throw AnimeBoxesImportError.noServers;
    final result = database.write((db) {
      final existing = [for (final data in db.column<Uint8List>('SELECT payload FROM servers ORDER BY position')) BooruServer.fromJson(decodeJsonObject(data))];
      final mapping = <String, String>{};
      var serverCount = 0;
      for (final imported in backup.servers) {
        final match = existing.where((server) => server.canonicalAddress == imported.canonicalAddress).firstOrNull;
        if (match != null) {
          mapping[imported.id] = match.id;
        } else {
          db.execute('INSERT INTO servers VALUES (?, ?, ?)', [imported.id, encodeSwiftJson(imported.toJson()), existing.length]);
          mapping[imported.id] = imported.id;
          existing.add(imported);
          serverCount += 1;
        }
      }
      if (options.folderID == 'anime-boxes') {
        db.execute("INSERT OR IGNORE INTO folders VALUES ('anime-boxes', 'Anime Boxes', 4287784115, (SELECT COUNT(*) FROM folders))");
      }
      if (options.folderID != 'by-site' && !db.exists('SELECT EXISTS(SELECT 1 FROM folders WHERE id = ?)', [options.folderID])) {
        throw const BooruError(BooruErrorKind.invalidResponse);
      }
      var added = 0, duplicates = 0;
      for (final favorite in backup.favorites) {
        final old = favorite.post;
        final id = mapping[old.serverID];
        if (id == null) continue;
        final post = BooruPost(
          serverID: id,
          postID: old.postID,
          previewURL: old.previewURL,
          sampleURL: old.sampleURL,
          fileURL: old.fileURL,
          width: old.width,
          height: old.height,
          tags: old.tags,
          artists: old.artists,
          rating: old.rating,
          score: old.score,
          fileExtension: old.fileExtension,
          poolIDs: old.poolIDs,
          metadataTags: old.metadataTags,
        );
        final landing = options.folderID == 'by-site' ? BooruStore.defaultFolder(id, db) : options.folderID;
        final folderID = BooruStoreFolderRules.smartDestination(post, landing, db, preferences.defaults);
        db.execute('INSERT OR IGNORE INTO favorites (server_id, post_id, payload, saved_at, folder_id) VALUES (?, ?, ?, ?, ?)', [
          id,
          post.postID,
          encodeSwiftJson(post.toJson()),
          favorite.savedAt,
          folderID,
        ]);
        if (db.changesCount > 0) {
          added += 1;
          TasteStore.record(TasteEventKind.imported, BooruStore.tasteItem(post, db), db);
        } else {
          duplicates += 1;
        }
      }
      if (options.folderID == 'by-site') BooruStore.organizeLegacyImportsIn(db);
      for (final id in mapping.values.toSet()) {
        if (options.history) {
          for (final search in backup.history) {
            db.execute('INSERT INTO history VALUES (?, ?, ?) ON CONFLICT(server_id, query) DO UPDATE SET used_at = MAX(used_at, excluded.used_at)', [
              id,
              search.text,
              search.date,
            ]);
            if (search.starred) db.execute("INSERT OR IGNORE INTO saved_tags VALUES (?, ?, 'search')", [id, search.text]);
          }
        }
        if (options.blacklist && backup.blacklist.isNotEmpty) {
          final old = db.value<String>('SELECT value FROM settings WHERE key = ?', ['blacklist.$id']) ?? '';
          final seen = <String>{};
          final merged = [...old.split(RegExp(r'\r?\n')), ...backup.blacklist].where((rule) => rule.isNotEmpty && seen.add(rule)).join('\n');
          db.execute('INSERT OR REPLACE INTO settings VALUES (?, ?)', ['blacklist.$id', merged]);
        }
      }
      if (options.selection) {
        final ids = [for (final id in backup.selectedIDs) ?mapping[id]];
        if (ids.isNotEmpty) db.execute("INSERT OR REPLACE INTO settings VALUES ('selected_servers', ?)", [encodeSwiftJsonString(ids)]);
      }
      return AnimeBoxesImportResult(added: added, duplicates: duplicates, serversAdded: serverCount);
    });
    refresh();
    return result;
  }
}
