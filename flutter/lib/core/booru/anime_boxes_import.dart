import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import '../storage/folder_rules.dart';
import '../support/sql_database.dart';
import '../support/l10n.dart';
import '../support/swift_json.dart';
import '../taste/taste_models.dart';
import '../taste/taste_store.dart';
import 'booru_models.dart';
import 'booru_store.dart';

enum AnimeBoxesImportError implements Exception {
  format,
  tooLarge,
  noServers,
  comicsBackup;

  String get message => switch (this) {
    format => L10n.text('Choose an Anime Boxes .abbj backup (version 1.0).'),
    comicsBackup => L10n.text('This is a comics app backup. Import it in Comics mode.'),
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

/// Which app's file a backup was read from. Every kind merges the same way.
enum AnimeBoxesSource { animeBoxes, bookmarkExport, imageAppDatabase }

/// An Anime Boxes `.abbj` backup, read without trusting its addresses: servers must be
/// valid HTTPS sites and media addresses are upgraded to HTTPS. Other image apps' bookmark
/// exports and databases are read into the same shape.
class AnimeBoxesBackup {
  const AnimeBoxesBackup({
    this.source = AnimeBoxesSource.animeBoxes,
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

  /// The folder the other image apps' favorites may go to instead of the site folders.
  static const importedFolderID = 'imported';

  final AnimeBoxesSource source;
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
    final handle = file.openSync();
    final head = handle.readSync(16);
    handle.closeSync();
    if (utf8.decode(head, allowMalformed: true).startsWith('SQLite format 3')) return readDatabase(file.path);
    if (file.lengthSync() > maximumBytes) throw AnimeBoxesImportError.tooLarge;
    final data = file.readAsBytesSync();
    return parseBookmarks(data) ?? parse(data);
  }

  /// A post page address, such as `/posts/1`, `/post/show/1` or `index.php?page=post&s=view&id=1`,
  /// as the server it belongs to and the post's number. The engine comes from the page's shape;
  /// it can't tell the old gallery engine from the new one, so an import maps onto a server
  /// already added with the same address, which keeps its own engine.
  static (BooruServer, int)? postPage(String raw) {
    final parts = Uri.tryParse(raw.trim());
    if (parts == null || !const {'http', 'https'}.contains(parts.scheme.toLowerCase()) || parts.host.isEmpty) return null;
    final path = parts.path;
    final BooruEngine engine;
    final int? postID;
    final String base;
    if (RegExp(r'^(.*?)/posts/([0-9]+)/?$').firstMatch(path) case final match?) {
      engine = BooruEngine.danbooru;
      postID = int.tryParse(match[2]!);
      base = match[1]!;
    } else if (RegExp(r'^(.*?)/post/show/([0-9]+)(?:/.*)?$').firstMatch(path) case final match?) {
      engine = BooruEngine.moebooru;
      postID = int.tryParse(match[2]!);
      base = match[1]!;
    } else if (path.endsWith('index.php') && parts.queryParameters['page'] == 'post' && parts.queryParameters['s'] == 'view') {
      engine = BooruEngine.gelbooru;
      postID = int.tryParse(parts.queryParameters['id'] ?? '');
      base = path.substring(0, path.length - 'index.php'.length);
    } else {
      return null;
    }
    if (postID == null || postID <= 0) return null;
    final String url;
    try {
      url = BooruServer.validatedURL('https://${parts.host.toLowerCase()}$base');
    } on Object {
      return null;
    }
    return (BooruServer(name: BooruServer.bareHost(Uri.parse(url).host), baseURL: url, engine: engine), postID);
  }

  /// Bookmarks exported as `{version, data: [...]}` or a bare list, each with the post's page
  /// address and its media addresses. Null when the data isn't such an export.
  static AnimeBoxesBackup? parseBookmarks(Uint8List data) {
    Object? json;
    try {
      json = jsonDecode(utf8.decode(data, allowMalformed: true));
    } on FormatException {
      return null;
    }
    final List<Map> rows;
    if (json is Map) {
      if (json['backupVersion'] != null || json['data'] is! List) return null;
      rows = (json['data'] as List).whereType<Map>().toList();
    } else if (json is List) {
      if (json.any((row) => row is Map && row['config'] is String && row['type'] != null)) throw AnimeBoxesImportError.comicsBackup;
      rows = json.whereType<Map>().toList();
    } else {
      return null;
    }
    if (!rows.any((row) => row['sourceUrl'] is String && (row['originalUrl'] != null || row['thumbnailUrl'] != null))) return null;
    final builder = _Builder(AnimeBoxesSource.bookmarkExport);
    for (final row in rows) {
      final created = row['createdAt'] is String ? DateTime.tryParse(row['createdAt'] as String) : null;
      builder.add(
        page: row['sourceUrl'] is String ? row['sourceUrl'] as String : null,
        preview: row['thumbnailUrl'],
        sample: row['sampleUrl'],
        file: row['originalUrl'],
        width: row['width'],
        height: row['height'],
        tags: row['tags'],
        format: row['format'] is String ? row['format'] as String : null,
        savedAt: created == null ? 0 : created.microsecondsSinceEpoch / 1e6,
      );
    }
    return builder.backup();
  }

  /// An image app's own database: favorite items with their page and media addresses, their
  /// tags, and the search history.
  static AnimeBoxesBackup readDatabase(String path) {
    final SqlDatabase db;
    try {
      db = SqlDatabase.openReadOnly(path);
    } on Object {
      throw AnimeBoxesImportError.format;
    }
    try {
      if (db.tableExists('LOCAL_FAVORITES') || db.tableExists('BookmarkArticle') || db.tableExists('MangaColumnModel')) {
        throw AnimeBoxesImportError.comicsBackup;
      }
      if (!db.tableExists('BooruItem')) throw AnimeBoxesImportError.format;
      final tags = <int, List<String>>{};
      if (db.tableExists('ImageTag') && db.tableExists('Tag')) {
        for (final row in db.rows(
          'SELECT it.booruItemID AS item, t.name AS name FROM ImageTag it JOIN Tag t ON t.id = it.tagID WHERE it.booruItemID IN (SELECT id FROM BooruItem WHERE isFavourite = 1)',
        )) {
          if ((row['item'], row['name']) case (final int item, final String name) when name.isNotEmpty) tags.putIfAbsent(item, () => []).add(name);
        }
      }
      final builder = _Builder(AnimeBoxesSource.imageAppDatabase);
      for (final row in db.rows('SELECT * FROM BooruItem WHERE isFavourite = 1 ORDER BY id DESC')) {
        builder.add(
          page: row['postURL'] is String ? row['postURL'] as String : null,
          preview: row['thumbnailURL'],
          sample: row['sampleURL'],
          file: row['fileURL'],
          width: null,
          height: null,
          tags: tags[row['id']] ?? const <String>[],
          format: null,
          savedAt: 0,
        );
      }
      if (db.tableExists('SearchHistory')) {
        for (final row in db.rows('SELECT * FROM SearchHistory ORDER BY id DESC')) {
          final text = row['searchText'] is String ? row['searchText'] as String : '';
          final date = row['timestamp'] is String ? DateTime.tryParse(row['timestamp'] as String) : null;
          builder.search(text, date == null ? 0 : date.microsecondsSinceEpoch / 1e6, row['isFavourite'] == 1);
        }
      }
      return builder.backup();
    } finally {
      db.close();
    }
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

/// Collects posts by the server their page belongs to.
class _Builder {
  _Builder(this.source);
  final AnimeBoxesSource source;
  final servers = <BooruServer>[];
  final favorites = <AnimeBoxesFavorite>[];
  final history = <AnimeBoxesSearch>[];
  final _seen = <String>{};
  var skippedFavorites = 0;
  var skippedHistory = 0;

  void add({
    required String? page,
    required Object? preview,
    required Object? sample,
    required Object? file,
    required Object? width,
    required Object? height,
    required Object? tags,
    required String? format,
    required double savedAt,
  }) {
    final found = page == null ? null : AnimeBoxesBackup.postPage(page);
    if (found == null) {
      skippedFavorites += 1;
      return;
    }
    final (candidate, postID) = found;
    final server = servers.where((server) => server.canonicalAddress == candidate.canonicalAddress).firstOrNull ?? (servers..add(candidate)).last;
    final fileURL = AnimeBoxesBackup._mediaURL(file, server.baseURL);
    final post = BooruPost(
      serverID: server.id,
      postID: postID,
      previewURL: AnimeBoxesBackup._mediaURL(preview, server.baseURL),
      sampleURL: AnimeBoxesBackup._mediaURL(sample, server.baseURL),
      fileURL: fileURL,
      width: (AnimeBoxesBackup._integer(width) ?? 0).clamp(0, 1 << 31),
      height: (AnimeBoxesBackup._integer(height) ?? 0).clamp(0, 1 << 31),
      tags: AnimeBoxesBackup._tokens(tags),
      artists: const [],
      rating: '',
      score: 0,
      fileExtension: ((format != null && format.isNotEmpty) ? format : (fileURL == null ? '' : urlPathExtension(fileURL))).toLowerCase(),
    );
    if (_seen.add(post.id)) favorites.add(AnimeBoxesFavorite(post, savedAt));
  }

  void search(String text, double date, bool starred) {
    if (text.trim().isEmpty) {
      skippedHistory += 1;
      return;
    }
    history.add(AnimeBoxesSearch(text: text, date: date, starred: starred));
  }

  AnimeBoxesBackup backup() => AnimeBoxesBackup(
    source: source,
    servers: servers,
    selectedIDs: const [],
    favorites: favorites,
    history: history,
    blacklist: const [],
    skippedServers: 0,
    skippedFavorites: skippedFavorites,
    skippedHistory: skippedHistory,
    skippedRules: 0,
  );
}

class AnimeBoxesImportOptions {
  const AnimeBoxesImportOptions({this.history = true, this.blacklist = true, this.selection = true, this.folderID = 'by-site'});
  final bool history;
  final bool blacklist;
  final bool selection;

  /// `by-site`, `anime-boxes`, `imported`, or an existing folder's ID.
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
      // A new server has its Uncategorized from the start, as one added by hand does.
      for (final id in mapping.values.toSet()) {
        BooruStore.uncategorized(id, db);
      }
      // The one folder for every image imported is global: it holds every server's images.
      if (options.folderID == 'anime-boxes') {
        db.execute(
          "INSERT OR IGNORE INTO folders (id, name, color, position) VALUES ('anime-boxes', 'Anime Boxes', 4287784115, (SELECT COUNT(*) FROM folders))",
        );
      } else if (options.folderID == AnimeBoxesBackup.importedFolderID) {
        db.execute('INSERT OR IGNORE INTO folders (id, name, color, position) VALUES (?, ?, 4287784115, (SELECT COUNT(*) FROM folders))', [
          AnimeBoxesBackup.importedFolderID,
          L10n.text('Imported'),
        ]);
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
      // A chosen folder of one server takes the others' images into their own folders of its name.
      BooruStore.settleFolders(db);
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
