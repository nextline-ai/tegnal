import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:crypto/crypto.dart';

import '../content/gallery_content.dart';
import '../content/gallery_id_parser.dart';
import '../content/keyed_catalog_source.dart';
import '../content/manga_urls.dart';
import '../content/site_account.dart';
import '../booru/booru_models.dart';
import '../storage/app_database.dart';
import '../storage/folder_rules.dart';
import '../support/l10n.dart';
import '../support/sql_database.dart';
import '../support/swift_json.dart';

/// `OtherAppLibrary.Format`: what kind of file a library was read from.
enum OtherAppFormat {
  viewerDatabase,
  settingsExport,
  downloadFolder,
  readerBackup,
  linkList;

  String get title => switch (this) {
    viewerDatabase => L10n.text('Viewer Database Export'),
    settingsExport => L10n.text('App Data Export'),
    downloadFolder => L10n.text('Download Folders'),
    readerBackup => L10n.text('Manga Reader Backup'),
    linkList => L10n.text('Link List or Bookmarks'),
  };
}

/// One work from the file.
class OtherAppEntry {
  OtherAppEntry(this.id, {this.key});
  final int id;
  String? key;
  String? title;
  List<String> artists = [];
  String? language;
  String? type;
  List<String> tags = [];
  String? publishedAt;
  DateTime? savedAt;

  bool get hasMetadata => (title ?? '').isNotEmpty || tags.isNotEmpty || artists.isNotEmpty;
}

/// A folder from the file. A null name is Unfiled.
class OtherAppShelf {
  OtherAppShelf(this.name, this.entries);
  final String? name;
  final List<OtherAppEntry> entries;
  String get displayName => name ?? L10n.text('Unfiled');
}

/// `OtherAppLibrary`: a comics library read from another app's backup, export or link list.
/// The file is only read; what it holds is shown first and merged when the person confirms.
///
/// Every format is recognized by its contents, never by its name:
/// - viewer database: an SQLite export with `LOCAL_FAVORITES`, `DOWNLOADS` and `HISTORY`
///   tables keyed by `GID` and `TOKEN`.
/// - app data export: a JSON list of `{type, config}` records whose gallery history record
///   (type 5) holds each work as JSON.
/// - download folders: folders that each keep a `manifest.json` with `gid`, `token` and `pages`.
/// - manga reader backup: a gzip-compressed protobuf backup; only entries whose address is
///   unmistakably a work of a supported catalog are kept.
/// - link list: browser bookmarks (HTML) or any text holding work links or bare numbers.
class OtherAppLibrary {
  OtherAppLibrary({required this.format, required this.shelves, this.history = const [], this.skipped = 0});
  final OtherAppFormat format;
  final List<OtherAppShelf> shelves;

  /// Works the person opened in the other app, imported only on request.
  final List<OtherAppEntry> history;

  /// Rows that were not a readable work of a supported catalog.
  final int skipped;

  int get workCount => {for (final shelf in shelves) for (final entry in shelf.entries) entry.id}.length;
  bool get isEmpty => workCount == 0 && history.isEmpty;
}

enum OtherAppImportError implements Exception {
  unrecognized,
  tooLarge,
  empty,
  mangaViewerDatabase,
  imageAppBackup;

  String get message => switch (this) {
    unrecognized => L10n.text('This file isn’t a backup, export or link list TEGNAL can read.'),
    tooLarge => L10n.text('This file exceeds the 256 MB import limit.'),
    empty => L10n.text('This file holds no works TEGNAL can open.'),
    mangaViewerDatabase => L10n.text('This is a manga viewer database. Import it with Import user.db or Import data.db.'),
    imageAppBackup => L10n.text('This is an image app backup. Import it in Images mode.'),
  };

  @override
  String toString() => message;
}

abstract final class OtherAppImport {
  static const maximumBytes = 256 * 1024 * 1024;

  /// Reads a picked file. Databases are read in place; everything else as bytes.
  static OtherAppLibrary read(File file, {List<String>? connectedHosts}) {
    final head = file.openSync()..setPositionSync(0);
    final bytes = head.readSync(16);
    head.closeSync();
    if (utf8.decode(bytes, allowMalformed: true).startsWith('SQLite format 3')) return readDatabase(file.path);
    if (file.lengthSync() > maximumBytes) throw OtherAppImportError.tooLarge;
    return parse(file.readAsBytesSync(), connectedHosts: connectedHosts);
  }

  /// Reads a file's bytes: a gzip backup, a JSON export, a manifest or text with links.
  static OtherAppLibrary parse(Uint8List data, {List<String>? connectedHosts}) {
    if (data.length > maximumBytes) throw OtherAppImportError.tooLarge;
    if (data.length > 2 && data[0] == 0x1F && data[1] == 0x8B) {
      final List<int> inflated;
      try {
        inflated = gzip.decode(data);
      } on Object {
        throw OtherAppImportError.unrecognized;
      }
      final library = readerBackup(Uint8List.fromList(inflated));
      if (library.isEmpty) throw OtherAppImportError.empty;
      return library;
    }
    final text = utf8.decode(data, allowMalformed: true);
    final trimmed = text.trim();
    if (trimmed.startsWith('[') || trimmed.startsWith('{')) {
      Object? json;
      try {
        json = jsonDecode(trimmed);
      } on FormatException {
        json = null;
      }
      if (json is List && json.any((record) => record is Map && record['config'] is String && record['type'] != null)) {
        final library = settingsExport(json.whereType<Map>().toList());
        if (library.isEmpty) throw OtherAppImportError.empty;
        return library;
      }
      if (json is Map) {
        if (manifestEntry(json) case final entry?) {
          return OtherAppLibrary(format: OtherAppFormat.downloadFolder, shelves: [OtherAppShelf(L10n.text('Downloads'), [entry])]);
        }
        if (json['data'] is List || json['servers'] is List) throw OtherAppImportError.imageAppBackup;
      }
    }
    final library = linkList(text, connectedHosts: connectedHosts ?? ComicSites.all);
    if (library.isEmpty) throw trimmed.isEmpty ? OtherAppImportError.unrecognized : OtherAppImportError.empty;
    return library;
  }

  // MARK: Viewer database export

  static OtherAppLibrary readDatabase(String path) {
    final SqlDatabase db;
    try {
      db = SqlDatabase.openReadOnly(path);
    } on Object {
      throw OtherAppImportError.unrecognized;
    }
    try {
      final tables = {for (final name in db.column<String>("SELECT name FROM sqlite_master WHERE type = 'table'")) name.toUpperCase()};
      if (tables.contains('BOOKMARKARTICLE') || tables.contains('MANGACOLUMNMODEL')) throw OtherAppImportError.mangaViewerDatabase;
      if (tables.contains('BOORUITEM')) throw OtherAppImportError.imageAppBackup;
      Set<String> columns(String table) => tables.contains(table) ? {for (final name in db.columns(table)) name.toUpperCase()} : const {};
      bool hasWorks(String table) => columns(table).contains('GID');
      if (!hasWorks('LOCAL_FAVORITES') && !hasWorks('DOWNLOADS') && !hasWorks('HISTORY')) throw OtherAppImportError.unrecognized;
      var skipped = 0;
      List<(OtherAppEntry, Map<String, Object?>)> entries(String table) {
        if (!hasWorks(table)) return const [];
        final order = columns(table).contains('TIME') ? 'ORDER BY TIME DESC' : '';
        final result = <(OtherAppEntry, Map<String, Object?>)>[];
        for (final row in db.rows('SELECT * FROM $table $order')) {
          final upper = {for (final entry in row.entries) entry.key.toUpperCase(): entry.value};
          final entry = _viewerEntry(upper);
          if (entry == null) {
            skipped += 1;
          } else {
            result.add((entry, upper));
          }
        }
        return result;
      }

      final shelves = <OtherAppShelf>[];
      final favorites = [for (final (entry, _) in entries('LOCAL_FAVORITES')) entry];
      if (favorites.isNotEmpty) shelves.add(OtherAppShelf(L10n.text('Favorites'), favorites));
      // Downloads keep their labels as folders, in the order the labels were made.
      final labelled = <String, List<OtherAppEntry>>{};
      final unlabelled = <OtherAppEntry>[];
      for (final (entry, row) in entries('DOWNLOADS')) {
        final label = (_string(row['LABEL']) ?? '').trim();
        if (label.isEmpty) {
          unlabelled.add(entry);
        } else {
          labelled.putIfAbsent(label, () => []).add(entry);
        }
      }
      if (unlabelled.isNotEmpty) shelves.add(OtherAppShelf(L10n.text('Downloads'), unlabelled));
      final labelOrder = tables.contains('DOWNLOAD_LABELS')
          ? [
              for (final row in db.rows('SELECT * FROM DOWNLOAD_LABELS')) ?_string(row['LABEL'] ?? row['label']),
            ]
          : <String>[];
      for (final label in [...labelOrder, ...(labelled.keys.toList()..sort())]) {
        if (labelled.remove(label) case final list?) shelves.add(OtherAppShelf(label, list));
      }
      final history = [for (final (entry, _) in entries('HISTORY')) entry];
      return OtherAppLibrary(format: OtherAppFormat.viewerDatabase, shelves: shelves, history: history, skipped: skipped);
    } finally {
      db.close();
    }
  }

  static String? _string(Object? value) => switch (value) {
    final String text => text,
    final int number => '$number',
    final double number => '$number',
    _ => null,
  };

  static int? _integer(Object? value) => switch (value) {
    final int number => number,
    final double number => number.toInt(),
    final String text => int.tryParse(text.trim()) ?? double.tryParse(text.trim())?.toInt(),
    _ => null,
  };

  static OtherAppEntry? _viewerEntry(Map<String, Object?> row) {
    final id = _integer(row['GID']);
    if (id == null || id < 1 || id > 9999999999) return null;
    final token = _string(row['TOKEN']);
    final entry = OtherAppEntry(id, key: token != null && GalleryKeys.isKey(token) ? token : null)
      ..title = _clean(_string(row['TITLE'])) ?? _clean(_string(row['TITLE_JPN']))
      ..type = switch (_integer(row['CATEGORY'])) {
        final int bits => categoryBit(bits),
        null => null,
      }
      ..language = switch (_string(row['SIMPLE_LANGUAGE'])) {
        final String code => languageCode(code),
        null => null,
      }
      ..publishedAt = switch (_string(row['POSTED'])) {
        final String posted => _isoDate(posted),
        null => null,
      };
    final time = _integer(row['TIME']);
    if (time != null && time > 0) entry.savedAt = DateTime.fromMillisecondsSinceEpoch(time, isUtc: true);
    return entry;
  }

  /// The category bits these exports keep in `CATEGORY`.
  static String? categoryBit(int value) => switch (value) {
    0x1 => 'misc',
    0x2 => 'doujinshi',
    0x4 => 'manga',
    0x8 => 'artistcg',
    0x10 => 'gamecg',
    0x20 => 'imageset',
    0x40 => 'cosplay',
    0x80 => 'photo',
    0x100 => 'non-h',
    0x200 => 'western',
    _ => null,
  };

  /// The short language codes these exports keep. Works without one are in the source language.
  static String? languageCode(String code) => switch (code.trim().toUpperCase()) {
    'JA' || 'JP' => 'japanese',
    'EN' => 'english',
    'ZH' || 'CN' => 'chinese',
    'KO' || 'KR' => 'korean',
    'ES' => 'spanish',
    'RU' => 'russian',
    'FR' => 'french',
    'PT' => 'portuguese',
    'TH' => 'thai',
    'DE' => 'german',
    'IT' => 'italian',
    'VI' => 'vietnamese',
    'PL' => 'polish',
    'HU' => 'hungarian',
    'NL' => 'dutch',
    _ => null,
  };

  /// A category name such as `Artist CG`, as the library keeps it.
  static String? categoryName(Object? name) {
    if (name is! String) return null;
    return switch (GalleryCategory.key(name)) {
      '' || 'private' || 'none' => null,
      'asianporn' => 'photo',
      final key => key,
    };
  }

  // MARK: App data export

  static OtherAppLibrary settingsExport(List<Map> records) {
    final history = <OtherAppEntry>[];
    var skipped = 0;
    for (final record in records) {
      if (_integer(record['type']) != 5 || record['config'] is! String) continue;
      Object? rows;
      try {
        rows = jsonDecode(record['config'] as String);
      } on FormatException {
        continue;
      }
      if (rows is! List) continue;
      for (final row in rows.whereType<Map>()) {
        Object? body;
        try {
          body = row['jsonBody'] is String ? jsonDecode(row['jsonBody'] as String) : null;
        } on FormatException {
          body = null;
        }
        final entry = body is Map ? _exportedGallery(body, _integer(row['gid'])) : null;
        if (entry == null) {
          skipped += 1;
          continue;
        }
        if (row['lastReadTime'] case final String time) entry.savedAt = parseDate(time);
        history.add(entry);
      }
    }
    history.sort((a, b) => (b.savedAt ?? DateTime(0)).compareTo(a.savedAt ?? DateTime(0)));
    return OtherAppLibrary(format: OtherAppFormat.settingsExport, shelves: const [], history: history, skipped: skipped);
  }

  static OtherAppEntry? _exportedGallery(Map body, int? id) {
    final url = body['galleryUrl'];
    final link = url is String ? KeyedCatalogSource.links(url).firstOrNull : null;
    final number = link?.id ?? id ?? _integer(body['gid']);
    if (number == null || number <= 0) return null;
    final token = body['token'];
    final entry = OtherAppEntry(number, key: link?.key ?? (token is String && GalleryKeys.isKey(token) ? token : null))
      ..title = _clean(body['title'] is String ? body['title'] as String : null)
      ..type = categoryName(body['category'])
      ..language = _clean(body['language'] is String ? body['language'] as String : null)?.toLowerCase()
      ..publishedAt = body['publishTime'] is String ? _isoDate(body['publishTime'] as String) : null;
    if (body['tags'] case final Map groups) {
      final tags = <(String, String)>[];
      for (final MapEntry(key: namespace, value: values) in groups.entries) {
        if (values is! List) continue;
        for (final value in values) {
          final data = value is Map && value['tagData'] is Map ? value['tagData'] as Map : null;
          final name = data?['_key'] ?? data?['key'] ?? (value is String ? value : null);
          if (name is String && name.isNotEmpty) tags.add((data?['namespace'] is String ? data!['namespace'] as String : '$namespace', name));
        }
      }
      _apply(tags, entry);
    }
    return entry;
  }

  /// Splits namespaced tags the way the library keeps them: artists apart, language as the
  /// work's language, the rest as `namespace:name` with local namespace names.
  static void _apply(List<(String, String)> tags, OtherAppEntry entry) {
    for (final (rawNamespace, name) in tags) {
      final namespace = rawNamespace.toLowerCase();
      switch (namespace) {
        case 'artist':
          if (!entry.artists.contains(name)) entry.artists.add(name);
        case 'language':
          if (entry.language == null && !const {'translated', 'rewrite'}.contains(name)) entry.language = name;
        default:
          final local = namespace == 'parody'
              ? 'series'
              : namespace == 'other' || namespace.isEmpty || namespace == 'misc'
              ? 'tag'
              : namespace;
          entry.tags.add('$local:$name');
      }
    }
  }

  // MARK: Download folders

  static OtherAppLibrary readDownloadFolder(Directory folder) {
    if (!folder.existsSync()) throw OtherAppImportError.unrecognized;
    final entries = <OtherAppEntry>[];
    final seen = <int>{};
    var skipped = 0;
    void walk(Directory directory, int depth) {
      if (depth > 3) return;
      final List<FileSystemEntity> children;
      try {
        children = directory.listSync(followLinks: false);
      } on FileSystemException {
        return;
      }
      for (final child in children) {
        final name = child.uri.pathSegments.where((part) => part.isNotEmpty).lastOrNull ?? '';
        if (name.startsWith('.')) continue;
        if (child is Directory) {
          walk(child, depth + 1);
        } else if (child is File && name == 'manifest.json' && child.lengthSync() <= 8 * 1024 * 1024) {
          Object? json;
          try {
            json = jsonDecode(child.readAsStringSync());
          } on Object {
            json = null;
          }
          final entry = json is Map ? manifestEntry(json) : null;
          if (entry == null) {
            skipped += 1;
          } else if (seen.add(entry.id)) {
            entries.add(entry);
          }
        }
      }
    }

    walk(folder, 0);
    if (entries.isEmpty) throw skipped > 0 ? OtherAppImportError.empty : OtherAppImportError.unrecognized;
    entries.sort((a, b) => (b.savedAt ?? DateTime(0)).compareTo(a.savedAt ?? DateTime(0)));
    return OtherAppLibrary(format: OtherAppFormat.downloadFolder, shelves: [OtherAppShelf(L10n.text('Downloads'), entries)], skipped: skipped);
  }

  static OtherAppEntry? manifestEntry(Map manifest) {
    final id = _integer(manifest['gid']);
    final key = manifest['token'];
    if (manifest['pages'] == null || id == null || id < 1 || id > 9999999999 || key is! String) return null;
    final language = _clean(manifest['language'] is String ? manifest['language'] as String : null)?.toLowerCase();
    final entry = OtherAppEntry(id, key: GalleryKeys.isKey(key) ? key : null)
      ..title = _clean(manifest['title'] is String ? manifest['title'] as String : null) ?? _clean(manifest['jpnTitle'] is String ? manifest['jpnTitle'] as String : null)
      ..type = categoryName(manifest['category'])
      ..language = const {'n/a', 'other'}.contains(language) ? null : language;
    // Dates in these manifests count seconds from 2001.
    if (manifest['postedDate'] case final num posted) {
      entry.publishedAt = iso8601(DateTime.utc(2001).add(Duration(microseconds: (posted * 1e6).round())));
    }
    final tags = <(String, String)>[];
    for (final group in (manifest['tags'] is List ? manifest['tags'] as List : const []).whereType<Map>()) {
      final namespace = group['rawNamespace'] is String ? group['rawNamespace'] as String : '';
      for (final content in (group['contents'] is List ? group['contents'] as List : const []).whereType<Map>()) {
        final text = content['text'];
        if (text is String && text.isNotEmpty) tags.add((content['rawNamespace'] is String ? content['rawNamespace'] as String : namespace, text));
      }
    }
    _apply(tags, entry);
    return entry;
  }

  // MARK: Manga reader backup

  static OtherAppLibrary readerBackup(Uint8List data, {Set<String> indexedSourceDigests = indexedSourceDigests}) {
    final reader = ProtoReader(data);
    final mangas = <Uint8List>[];
    final categories = <(int, String)>[];
    final indexedSources = <int>{};
    for (var field = reader.next(); field != null; field = reader.next()) {
      switch (field) {
        case (1, 2):
          mangas.add(reader.lengthDelimited());
        case (101, 2):
          final source = ProtoReader(reader.lengthDelimited());
          var name = '';
          var id = 0;
          for (var inner = source.next(); inner != null; inner = source.next()) {
            switch (inner) {
              case (1, 2):
                name = utf8.decode(source.lengthDelimited(), allowMalformed: true);
              case (2, 0):
                id = source.varint();
              default:
                source.skip(inner.$2);
            }
          }
          if (isIndexedSource(name, digests: indexedSourceDigests)) indexedSources.add(id);
        case (2, 2):
          final category = ProtoReader(reader.lengthDelimited());
          var name = '';
          var order = 0;
          for (var inner = category.next(); inner != null; inner = category.next()) {
            switch (inner) {
              case (1, 2):
                name = utf8.decode(category.lengthDelimited(), allowMalformed: true);
              case (2, 0):
                order = category.varint();
              default:
                category.skip(inner.$2);
            }
          }
          if (name.isNotEmpty) categories.add((order, name));
        default:
          reader.skip(field.$2);
      }
    }
    if (mangas.isEmpty && categories.isEmpty) throw OtherAppImportError.unrecognized;
    final byCategory = <int, List<OtherAppEntry>>{};
    final unfiled = <OtherAppEntry>[];
    var skipped = 0;
    for (final bytes in mangas) {
      final manga = ProtoReader(bytes);
      var url = '', title = '', artist = '', author = '', added = 0, favorite = true, source = 0;
      final orders = <int>[];
      for (var field = manga.next(); field != null; field = manga.next()) {
        switch (field) {
          case (1, 0):
            source = manga.varint();
          case (2, 2):
            url = utf8.decode(manga.lengthDelimited(), allowMalformed: true);
          case (3, 2):
            title = utf8.decode(manga.lengthDelimited(), allowMalformed: true);
          case (4, 2):
            artist = utf8.decode(manga.lengthDelimited(), allowMalformed: true);
          case (5, 2):
            author = utf8.decode(manga.lengthDelimited(), allowMalformed: true);
          case (13, 0):
            added = manga.varint();
          case (17, 0):
            orders.add(manga.varint());
          case (17, 2):
            final packed = ProtoReader(manga.lengthDelimited());
            while (!packed.isAtEnd) {
              orders.add(packed.varint());
            }
          case (100, 0):
            favorite = manga.varint() != 0;
          default:
            manga.skip(field.$2);
        }
      }
      if (!favorite) continue;
      final link = strictLinks(url, connectedHosts: const []).firstOrNull ?? (indexedSources.contains(source) ? _indexedSourceLink(url) : null);
      if (link == null) {
        skipped += 1;
        continue;
      }
      final artists = <String>[];
      for (final name in [artist, author]) {
        for (final part in name.split(',')) {
          final trimmed = part.trim();
          if (trimmed.isNotEmpty && !artists.contains(trimmed)) artists.add(trimmed);
        }
      }
      final entry = OtherAppEntry(link.$1, key: link.$2)
        ..title = _clean(title)
        ..artists = artists;
      if (added > 0) entry.savedAt = DateTime.fromMillisecondsSinceEpoch(added, isUtc: true);
      final known = orders.where((order) => categories.any((category) => category.$1 == order)).toList();
      if (known.isEmpty) unfiled.add(entry);
      for (final order in known) {
        byCategory.putIfAbsent(order, () => []).add(entry);
      }
    }
    final shelves = <OtherAppShelf>[if (unfiled.isNotEmpty) OtherAppShelf(null, unfiled)];
    for (final (order, name) in [...categories]..sort((a, b) => a.$1.compareTo(b.$1))) {
      if (byCategory.remove(order) case final entries?) shelves.add(OtherAppShelf(name, entries));
    }
    return OtherAppLibrary(format: OtherAppFormat.readerBackup, shelves: shelves, skipped: skipped);
  }

  /// The indexed catalog's own source in a reader backup, recognized by a SHA-256 digest of its
  /// lowercased name so the name never appears here. Its entries keep addresses that end in
  /// the work's number, such as `/type/title-123.html`, which elsewhere could be anything.
  static const indexedSourceDigests = {
    '548bcf3e89779bf069f4f1a8cbc4e9e1578b93459ab280db9f6f6328e0a7b4ef',
    '18a79419bbf79acdbb5373ec92b740e97544190c818551fabb8cb8cbfa089be4',
  };

  static bool isIndexedSource(String name, {Set<String> digests = indexedSourceDigests}) => digests.contains(digest(name));

  static String digest(String name) => sha256.convert(utf8.encode(name.trim().toLowerCase())).toString();

  static final _numberedPagePattern = RegExp(r'(?:/(?:manga|galleries|reader)/|-)([0-9]{4,10})\.html(?:[?#].*)?$', caseSensitive: false);

  static (int, String?)? _indexedSourceLink(String url) => switch (int.tryParse(_numberedPagePattern.firstMatch(url)?.group(1) ?? '')) {
    final int id => (id, null),
    null => null,
  };

  // MARK: Link lists and browser bookmarks

  static final _bookmarkToken = RegExp(r'<H3([^>]*)>(.*?)</H3>|<DL[^>]*>|</DL>|<A\s([^>]*)>', caseSensitive: false, dotAll: true);

  static OtherAppLibrary linkList(String text, {required List<String> connectedHosts}) {
    final isBookmarkFile = RegExp('<DL', caseSensitive: false).hasMatch(text) && RegExp('<A ', caseSensitive: false).hasMatch(text);
    final order = <String?>[];
    final grouped = <String?, List<OtherAppEntry>>{};
    final seen = <String?, Set<int>>{};
    void add(OtherAppEntry entry, String? folder) {
      if (!grouped.containsKey(folder)) {
        order.add(folder);
        grouped[folder] = [];
      }
      if (!seen.putIfAbsent(folder, () => {}).add(entry.id)) return;
      grouped[folder]!.add(entry);
    }

    if (isBookmarkFile) {
      // Netscape bookmark files nest folders as `<DT><H3>name</H3><DL> … </DL>`.
      final stack = <String?>[];
      var hasPending = false;
      String? pending;
      for (final match in _bookmarkToken.allMatches(text)) {
        final token = match[0]!;
        if (match[2] != null) {
          final name = NativeGallery.decodeEntities(match[2]!).trim();
          // The browser's own toolbar folder is where loose bookmarks live.
          pending = match[1]!.toUpperCase().contains('PERSONAL_TOOLBAR_FOLDER') || name.isEmpty ? null : name;
          hasPending = true;
        } else if (token.toUpperCase().startsWith('<DL')) {
          stack.add(hasPending ? pending : (stack.isEmpty ? null : stack.last));
          hasPending = false;
          pending = null;
        } else if (token.toUpperCase() == '</DL>') {
          if (stack.isNotEmpty) stack.removeLast();
        } else if (match[3] != null) {
          final attributes = match[3]!;
          final href = _attribute('HREF', attributes);
          if (href == null) continue;
          for (final (id, key) in strictLinks(NativeGallery.decodeEntities(href), connectedHosts: connectedHosts)) {
            final entry = OtherAppEntry(id, key: key);
            final added = double.tryParse(_attribute('ADD_DATE', attributes) ?? '');
            if (added != null && added > 0) entry.savedAt = DateTime.fromMillisecondsSinceEpoch((added * 1000).round(), isUtc: true);
            add(entry, stack.isEmpty ? null : stack.last);
          }
        }
      }
    } else {
      for (final (id, key) in strictLinks(text, connectedHosts: connectedHosts)) {
        add(OtherAppEntry(id, key: key), null);
      }
      // A plain list of numbers, one or more per line, names works directly.
      if (grouped.isEmpty) {
        final tokens = text.split(RegExp(r'[ \t\r\n,;]')).where((token) => token.isNotEmpty).toList();
        if (tokens.isNotEmpty && tokens.every((token) => RegExp(r'^[0-9]{4,10}$').hasMatch(token))) {
          for (final token in tokens) {
            final id = int.parse(token);
            if (id >= 1000) add(OtherAppEntry(id), null);
          }
        }
      }
    }
    return OtherAppLibrary(format: OtherAppFormat.linkList, shelves: [for (final folder in order) OtherAppShelf(folder, grouped[folder]!)]);
  }

  static final _indexedPattern = RegExp(r'/(?:galleries|reader)/([0-9]{4,10})\.html', caseSensitive: false);
  static final _urlPattern = RegExp('https?://[^\\s"\'<>]+', caseSensitive: false);

  /// Work links whose shape cannot belong to anything else: a number with its 10-character key,
  /// and the indexed catalog's `galleries/` and `reader/` pages. The shorter shapes (a title
  /// ending in the number, the document catalog's `r/`) are taken only from connected sites.
  static List<(int, String?)> strictLinks(String text, {required List<String> connectedHosts}) {
    final result = <(int, String?)>[];
    final seen = <int>{};
    void add(int id, String? key) {
      if (id <= 0 || (key == null && (id < 1000 || id > 9999999999)) || !seen.add(id)) return;
      result.add((id, key));
    }

    for (final link in [...KeyedCatalogSource.links(text), ...KeyedCatalogSource.viewerLinks(text)]) {
      add(link.id, link.key);
    }
    for (final match in _indexedPattern.allMatches(text)) {
      if (int.tryParse(match[1]!) case final id?) add(id, null);
    }
    final hosts = {for (final host in connectedHosts) BooruServer.bareHost(host)}..remove('');
    if (hosts.isEmpty) return result;
    for (final match in _urlPattern.allMatches(text)) {
      final url = Uri.tryParse(match[0]!);
      if (url == null || !hosts.contains(BooruServer.bareHost(url.host))) continue;
      for (final id in GalleryIDParser.parse(url.toString())) {
        add(id, null);
      }
    }
    return result;
  }

  // MARK: Helpers

  static String? _clean(String? text) {
    final trimmed = text?.trim();
    if (trimmed == null || trimmed.isEmpty) return null;
    return NativeGallery.decodeEntities(trimmed);
  }

  static String? _attribute(String name, String attributes) =>
      RegExp('$name\\s*=\\s*"([^"]*)"', caseSensitive: false).firstMatch(attributes)?.group(1);

  /// Times such as `2024-04-29 23:47`, `2024-04-29 23:47:23.370` or ISO 8601.
  static DateTime? parseDate(String text) => DateTime.tryParse(text.trim());

  static String? _isoDate(String text) => switch (parseDate(text)) {
    final DateTime date => iso8601(date),
    null => null,
  };
}

/// `OtherAppImportOptions`.
class OtherAppImportOptions {
  const OtherAppImportOptions({this.includeHistory = false, this.destination});

  /// Also save the works from the other app's reading history, in a folder of their own.
  final bool includeHistory;

  /// Every work goes into this folder instead of the file's own folders.
  final int? destination;
}

class OtherAppImportResult {
  const OtherAppImportResult({required this.added, required this.existing, required this.folders});
  final int added;
  final int existing;
  final int folders;

  @override
  bool operator ==(Object other) => other is OtherAppImportResult && other.added == added && other.existing == existing && other.folders == folders;
  @override
  int get hashCode => Object.hash(added, existing, folders);
  @override
  String toString() => 'OtherAppImportResult(added: $added, existing: $existing, folders: $folders)';
}

extension AppDatabaseOtherAppImport on AppDatabase {
  /// Saves the file's works into folders named like the file's. A work already in the library
  /// keeps its information and folders and is only added to the new folder as well. Keys
  /// in the file are remembered so each work opens without a search.
  OtherAppImportResult importOtherApp(OtherAppLibrary library, {OtherAppImportOptions options = const OtherAppImportOptions(), bool Function()? cancelled}) {
    final shelves = [
      ...library.shelves,
      if (options.includeHistory && library.history.isNotEmpty) OtherAppShelf(L10n.text('Reading History'), library.history),
    ];
    final before = {for (final folder in listFolders()) folder.id};
    var added = 0, existing = 0;
    final handled = <int>{};
    final keys = <(int, String)>[];
    try {
      for (final shelf in shelves) {
        if (shelf.entries.isEmpty) continue;
        if (cancelled?.call() ?? false) break;
        final int? folderID = options.destination ?? (shelf.name == null ? unfiledFolderID() : createFolder(name: shelf.name!).id);
        if (folderID == null) continue;
        for (final entry in shelf.entries) {
          if (cancelled?.call() ?? false) break;
          if (entry.key case final key?) keys.add((entry.id, key));
          if (getWork(entry.id) != null) {
            addWork(entry.id, folderID);
            if (handled.add(entry.id)) existing += 1;
            continue;
          }
          handled.add(entry.id);
          upsertWork(
            galleryId: entry.id,
            folderId: folderID,
            title: entry.title,
            artists: entry.artists.isEmpty ? null : entry.artists.join(', '),
            language: entry.language,
            type: entry.type,
            tags: entry.tags.isEmpty ? null : entry.tags.join(', '),
            publishedAt: entry.publishedAt,
            bookmarkedAt: entry.savedAt == null ? null : iso8601(entry.savedAt),
            metadataSource: entry.hasMetadata ? 'remote' : null,
          );
          added += 1;
        }
      }
    } finally {
      GalleryKeys.shared.rememberAll(keys);
    }
    final created = {for (final folder in listFolders()) folder.id}.difference(before).length;
    return OtherAppImportResult(added: added, existing: existing, folders: created);
  }
}

/// Just enough of the protobuf wire format to walk a backup's messages.
class ProtoReader {
  ProtoReader(this._bytes);
  final Uint8List _bytes;
  var _index = 0;

  bool get isAtEnd => _index >= _bytes.length;

  /// The next field's number and wire type, or null at the end.
  (int, int)? next() {
    if (isAtEnd) return null;
    final tag = varint();
    if (tag >> 3 <= 0) throw OtherAppImportError.unrecognized;
    return (tag >> 3, tag & 7);
  }

  int varint() {
    var value = 0, shift = 0;
    while (true) {
      if (_index >= _bytes.length || shift >= 64) throw OtherAppImportError.unrecognized;
      final byte = _bytes[_index++];
      value |= (byte & 0x7F) << shift;
      if (byte & 0x80 == 0) return value;
      shift += 7;
    }
  }

  Uint8List lengthDelimited() {
    final length = varint();
    if (length < 0 || length > _bytes.length - _index) throw OtherAppImportError.unrecognized;
    final slice = Uint8List.sublistView(_bytes, _index, _index + length);
    _index += length;
    return slice;
  }

  void skip(int wire) {
    switch (wire) {
      case 0:
        varint();
      case 1:
        _index += 8;
      case 2:
        lengthDelimited();
      case 5:
        _index += 4;
      default:
        throw OtherAppImportError.unrecognized;
    }
    if (_index > _bytes.length) throw OtherAppImportError.unrecognized;
  }
}
