import 'dart:convert';
import 'dart:io';

import 'package:crypto/crypto.dart';
import 'package:sqlite3/sqlite3.dart';

import '../core/content.dart';
import 'backup_codec.dart';
import 'library_store.dart';

class LegacyImportSummary extends BackupSummary {
  const LegacyImportSummary({
    super.workCount = 0,
    super.folderCount = 0,
    this.artistCount = 0,
    this.catalogCount = 0,
    this.matchedCount = 0,
    this.duplicates = 0,
    this.skipped = 0,
    this.serverCount = 0,
    this.isCatalog = false,
  });
  final bool isCatalog;
  final int artistCount,
      catalogCount,
      matchedCount,
      duplicates,
      skipped,
      serverCount;
}

class LegacyImportCancelled implements Exception {
  const LegacyImportCancelled();
  @override
  String toString() => 'Import canceled. No library changes were committed.';
}

/// Imports only an explicitly selected file, opening source SQLite read-only.
class LegacyImport {
  LegacyImport(this.store);
  final LibraryStore store;
  BackupCodec get _codec => BackupCodec(store);
  static const _maxAnimeBytes = 64 * 1024 * 1024;
  static const _palette = [
    0xFF2563EB,
    0xFF059669,
    0xFFD97706,
    0xFFDB2777,
    0xFF7C3AED,
    0xFF0891B2,
    0xFFEA580C,
    0xFF4F46E5,
    0xFF0D9488,
    0xFF65A30D,
  ];

  Future<LegacyImportSummary> inspectFile(String path) async {
    if (path.toLowerCase().endsWith('.abbj')) {
      final file = File(path);
      _require(
        await file.length() <= _maxAnimeBytes,
        'Image-library backup exceeds 64 MiB.',
      );
      return inspectImageLibrary(await file.readAsString());
    }
    final source = sqlite3.open(path, mode: OpenMode.readOnly);
    try {
      final user = _table(source, 'BookmarkArticle');
      if (user != null) return _userPlan(source).summary;
      final table = _catalogTable(source);
      _require(table != null, 'Unsupported manga database schema.');
      final ids = store.items(AppMode.manga).map((s) => s.item.id).toList();
      var matched = 0;
      for (var i = 0; i < ids.length; i += 400) {
        final chunk = ids.skip(i).take(400).toList();
        matched += source
            .select(
              'SELECT Id FROM ${_quote(table!)} WHERE Id IN (${List.filled(chunk.length, '?').join(',')})',
              chunk,
            )
            .length;
      }
      return LegacyImportSummary(
        workCount: matched,
        matchedCount: matched,
        catalogCount: matched,
        isCatalog: true,
      );
    } finally {
      source.close();
    }
  }

  Future<LegacyImportSummary> importFile(
    String path, {
    bool fullCatalog = false,
    bool Function()? isCancelled,
    void Function(int)? onProgress,
  }) async {
    _checkCancel(isCancelled);
    if (path.toLowerCase().endsWith('.abbj')) {
      final file = File(path);
      _require(
        await file.length() <= _maxAnimeBytes,
        'Image-library backup exceeds 64 MiB.',
      );
      final text = await file.readAsString();
      _checkCancel(isCancelled);
      return importImageLibrary(text);
    }
    final source = sqlite3.open(path, mode: OpenMode.readOnly);
    try {
      source.execute(
        'BEGIN',
      ); // One consistent read snapshot throughout staging.
      if (_table(source, 'BookmarkArticle') != null) {
        final plan = _userPlan(source);
        _checkCancel(isCancelled);
        store.transaction(() {
          _codec.importJson(jsonEncode(plan.envelope));
          // Native drops the default association when a named folder is present.
          final defaultIds = store
              .folders(AppMode.manga)
              .where((f) => f.name == '미분류')
              .map((f) => f.id)
              .toSet();
          for (final saved in store.items(AppMode.manga)) {
            if (saved.folderIds.any((id) => !defaultIds.contains(id)) &&
                saved.folderIds.any(defaultIds.contains)) {
              store.saveItem(
                saved.item,
                folderIds: saved.folderIds
                    .where((id) => !defaultIds.contains(id))
                    .toList(),
              );
            }
          }
        });
        return plan.summary;
      }
      final table = _catalogTable(source);
      _require(table != null, 'Unsupported manga database schema.');
      return await _importCatalog(
        source,
        table!,
        fullCatalog: fullCatalog,
        isCancelled: isCancelled,
        onProgress: onProgress,
      );
    } finally {
      source.close();
    }
  }

  LegacyImportSummary inspectImageLibrary(String text) =>
      _animePlan(text).summary;
  LegacyImportSummary importImageLibrary(String text) {
    final plan = _animePlan(text);
    _codec.importJson(jsonEncode(plan.envelope));
    return plan.summary;
  }

  _LegacyPlan _userPlan(Database source) {
    final articleTable = _table(source, 'BookmarkArticle')!;
    final groupTable = _table(source, 'BookmarkGroup');
    _require(groupTable != null, 'BookmarkGroup table is missing.');
    final groupRows =
        source.select('SELECT * FROM ${_quote(groupTable!)}').toList()..sort(
          (a, b) => (_int(_field(a, ['Gorder'])) ?? 0).compareTo(
            _int(_field(b, ['Gorder'])) ?? 0,
          ),
        );
    final folders = <String, Map<String, dynamic>>{};
    final groupNames = <int, String>{};
    final usedColors = store.folders(AppMode.manga).map((f) => f.color).toSet();
    var skipped = 0;
    for (final row in groupRows) {
      final id = _int(_field(row, ['Id']));
      if (id == null) {
        skipped++;
        continue;
      }
      var name = _string(_field(row, ['Name'])) ?? 'Folders';
      if ([0, 1].contains(id) && name.endsWith('_default')) name = '미분류';
      if (name.trim().isEmpty) {
        skipped++;
        continue;
      }
      final existing = store
          .folders(AppMode.manga)
          .where((f) => f.name == name)
          .firstOrNull;
      final raw = _int(_field(row, ['Color']));
      final color =
          existing?.color ??
          (raw != null &&
                  raw > 0 &&
                  raw <= 0xFFFFFFFF &&
                  raw != 4294940672 &&
                  !usedColors.contains(raw)
              ? raw
              : _nextColor(usedColors));
      usedColors.add(color);
      groupNames[id] = name;
      folders.putIfAbsent(
        name,
        () => {
          'name': name,
          'color': color,
          'sort_order': folders.length,
          'source_group_id': id,
          'description': ?_string(_field(row, ['Description'])),
        },
      );
    }
    folders.putIfAbsent(
      '미분류',
      () => {
        'name': '미분류',
        'color': _nextColor(usedColors),
        'sort_order': folders.length,
      },
    );
    groupNames.putIfAbsent(0, () => '미분류');
    groupNames.putIfAbsent(1, () => '미분류');
    final works = <int, Map<String, dynamic>>{};
    var duplicates = 0;
    final current = {
      for (final item in store.items(AppMode.manga)) item.item.id: item,
    };
    final articles =
        source.select('SELECT * FROM ${_quote(articleTable)}').toList()..sort(
          (a, b) => (_string(_field(b, ['DateTime'])) ?? '').compareTo(
            _string(_field(a, ['DateTime'])) ?? '',
          ),
        );
    for (final row in articles) {
      final id = _int(_field(row, ['Article', 'GalleryId', 'Id']));
      if (id == null || id <= 0) {
        skipped++;
        continue;
      }
      final name =
          groupNames[_int(_field(row, ['GroupId', 'group_id', 'Group']))] ??
          '미분류';
      final previous = works[id];
      if (previous != null || current.containsKey(id)) duplicates++;
      final metadata =
          store.portable('legacy.catalog.$id') ?? <String, dynamic>{};
      final date = _bookmarkDate(_field(row, ['DateTime']));
      works[id] = {
        ...metadata,
        'gallery_id': id,
        if (previous?['bookmarked_at'] != null)
          'bookmarked_at': previous!['bookmarked_at']
        else
          'bookmarked_at': ?date,
        'folders': {
          ...?(previous?['folders'] as List?)?.cast<String>(),
          name,
        }.toList(),
      };
    }
    final artistTable = _table(source, 'BookmarkArtist');
    final artists = <String, Map<String, dynamic>>{};
    if (artistTable != null) {
      for (final row in source.select('SELECT * FROM ${_quote(artistTable)}')) {
        final name = _string(_field(row, ['Artist']));
        if (name == null || name.trim().isEmpty) {
          skipped++;
          continue;
        }
        final kind = (_int(_field(row, ['IsGroup'])) ?? 0) == 0 ? 0 : 1;
        artists['$kind:$name'] = {'name': name, 'kind': kind};
      }
    }
    final envelope = {
      'version': 2,
      'folders': folders.values.toList(),
      'works': works.values.toList(),
      'artists': artists.values.toList(),
    };
    _codec.inspect(jsonEncode(envelope));
    return _LegacyPlan(
      envelope,
      LegacyImportSummary(
        workCount: works.length,
        folderCount: folders.length,
        artistCount: artists.length,
        duplicates: duplicates,
        skipped: skipped,
      ),
    );
  }

  Future<LegacyImportSummary> _importCatalog(
    Database source,
    String table, {
    required bool fullCatalog,
    bool Function()? isCancelled,
    void Function(int)? onProgress,
  }) async {
    // Disk staging bounds memory while allowing cancellation before an atomic commit.
    final directory = await Directory.systemTemp.createTemp('tegnal-catalog-');
    final staging = sqlite3.open('${directory.path}/catalog.sqlite');
    try {
      staging.execute(
        'CREATE TABLE stage (id INTEGER PRIMARY KEY,payload TEXT NOT NULL)',
      );
      final saved = {
        for (final item in store.items(AppMode.manga)) item.item.id: item,
      };
      var count = 0, last = 0, skipped = 0;
      if (fullCatalog) {
        while (true) {
          _checkCancel(isCancelled);
          final startCursor = last;
          final rows = source.select(
            'SELECT * FROM ${_quote(table)} WHERE Id > ? ORDER BY Id LIMIT ?',
            [last, 1000],
          );
          if (rows.isEmpty) break;
          staging.execute('BEGIN');
          try {
            for (final row in rows) {
              final id = _int(_field(row, ['Id']));
              if (id == null || id <= last) {
                skipped++;
                continue;
              }
              last = id;
              final record = _catalogRecord(row);
              staging.execute('INSERT OR REPLACE INTO stage VALUES (?,?)', [
                id,
                jsonEncode(record),
              ]);
              count++;
            }
            staging.execute('COMMIT');
          } catch (_) {
            staging.execute('ROLLBACK');
            rethrow;
          }
          _require(
            last > startCursor,
            'Catalog cursor did not advance over numeric IDs.',
          );
          onProgress?.call(count);
          await Future<void>.delayed(Duration.zero);
          if (rows.length < 1000) break;
        }
      } else {
        final ids = saved.keys.toList();
        for (var offset = 0; offset < ids.length; offset += 400) {
          _checkCancel(isCancelled);
          final chunk = ids.skip(offset).take(400).toList();
          final rows = source.select(
            'SELECT * FROM ${_quote(table)} WHERE Id IN (${List.filled(chunk.length, '?').join(',')})',
            chunk,
          );
          for (final row in rows) {
            final record = _catalogRecord(row);
            staging.execute('INSERT OR REPLACE INTO stage VALUES (?,?)', [
              record['gallery_id'],
              jsonEncode(record),
            ]);
            count++;
          }
          onProgress?.call(count);
          await Future<void>.delayed(Duration.zero);
        }
      }
      _checkCancel(isCancelled);
      var matched = 0;
      store.transaction(() {
        var cursor = 0;
        while (true) {
          _checkCancel(isCancelled);
          final rows = staging.select(
            'SELECT * FROM stage WHERE id > ? ORDER BY id LIMIT ?',
            [cursor, 1000],
          );
          if (rows.isEmpty) break;
          final updates = <Map<String, dynamic>>[];
          for (final row in rows) {
            cursor = row['id'] as int;
            final record = Map<String, dynamic>.from(
              jsonDecode(row['payload'] as String) as Map,
            );
            store.setPortable('legacy.catalog.$cursor', record);
            final current = saved[cursor];
            if (current != null) {
              final update = Map<String, dynamic>.from(record);
              if (current.item.metadata['metadata_source'] == 'manual') {
                update['metadata_source'] = 'manual';
                for (final key in [
                  'title',
                  'artists',
                  'language',
                  'type',
                  'series',
                  'groups',
                  'tags',
                ]) {
                  final existing = key == 'title'
                      ? current.item.title
                      : key == 'artists'
                      ? current.item.artists.join(', ')
                      : key == 'tags'
                      ? current.item.tags.join(', ')
                      : current.item.metadata[key];
                  if (existing is String && existing.isNotEmpty) {
                    update.remove(key);
                  }
                }
              }
              if (current.item.metadata['published_at'] != null) {
                update.remove('published_at');
              }
              updates.add(update);
              matched++;
            }
          }
          if (updates.isNotEmpty) {
            _codec.importJson(
              jsonEncode({
                'version': 2,
                'folders': [],
                'works': updates,
                'artists': [],
              }),
            );
          }
        }
      });
      return LegacyImportSummary(
        workCount: matched,
        matchedCount: matched,
        catalogCount: count,
        skipped: skipped,
      );
    } finally {
      staging.close();
      await directory.delete(recursive: true);
    }
  }

  Map<String, dynamic> _catalogRecord(Row row) {
    final id = _int(_field(row, ['Id']));
    _require(id != null && id > 0, 'Invalid catalog gallery ID.');
    return {
      'gallery_id': id,
      'metadata_source': 'catalog',
      'catalog_matched': true,
      'title': ?_unescape(_string(_field(row, ['Title']))),
      for (final (source, target) in [
        ('Type', 'type'),
        ('Language', 'language'),
      ])
        target: ?_string(_field(row, [source])),
      for (final (source, target) in [
        ('Artists', 'artists'),
        ('Groups', 'groups'),
        ('Series', 'series'),
        ('Characters', 'characters'),
        ('Tags', 'tags'),
      ])
        target: ?_piped(_string(_field(row, [source]))),
      'published_at': ?_published(_field(row, ['Published'])),
    };
  }

  _LegacyPlan _animePlan(String text) {
    _require(
      utf8.encode(text).length <= _maxAnimeBytes,
      'Image-library backup exceeds 64 MiB.',
    );
    final value = jsonDecode(text);
    _require(value is Map<String, dynamic>, 'Invalid image-library backup.');
    final root = value as Map<String, dynamic>;
    _require(
      root['backupVersion'] == '1.0' &&
          root['servers'] is List &&
          root['favorites'] is List,
      'Choose an .abbj image-library backup (version 1.0).',
    );
    final sources = <String, SourceConfig>{}, selected = <String>{};
    var skipped = 0;
    for (final raw in root['servers'] as List) {
      if (raw is! Map) {
        skipped++;
        continue;
      }
      final input = raw['url'];
      Uri uri;
      try {
        if (input is! String || input.isEmpty) {
          skipped++;
          continue;
        }
        uri = SourceConfig.validateUrl(
          input.replaceFirst(RegExp(r'^http://'), 'https://'),
        );
      } on FormatException {
        skipped++;
        continue;
      }
      uri = uri.replace(
        path: uri.path.replaceFirst(RegExp(r'/index\.php$'), ''),
      );
      final kind = switch (_int(raw['type'])) {
        1 =>
          uri.host.endsWith('.booru.org')
              ? SourceKind.oldGelbooru
              : SourceKind.gelbooru,
        4 => SourceKind.oldGelbooru,
        3 => SourceKind.danbooru,
        _ =>
          {'yande.re', 'konachan.com', 'konachan.net'}.contains(uri.host)
              ? SourceKind.moebooru
              : null,
      };
      if (kind == null) {
        skipped++;
        continue;
      }
      final origin = _canonical(uri);
      final id =
          'anime-boxes:${sha256.convert(utf8.encode(origin)).toString().substring(0, 24)}';
      final source = sources.putIfAbsent(
        origin,
        () => SourceConfig(
          id: id,
          name:
              raw['serverName'] is String &&
                  (raw['serverName'] as String).isNotEmpty
              ? raw['serverName'] as String
              : uri.host,
          baseUrl: uri,
          kind: kind,
        ),
      );
      if (raw['isSelected'] == true) selected.add(source.id);
    }
    _require(sources.isNotEmpty, 'This backup contains no supported servers.');
    final old = store.portable('backup.images') ?? {};
    final oldFolderMetadata = (old['folderMetadata'] as Map?) ?? {};
    final folders = <String, Map<String, dynamic>>{};
    final usedColors = store.folders(AppMode.booru).map((f) => f.color).toSet();
    for (final f in store.folders(AppMode.booru)) {
      final metadata = oldFolderMetadata[f.id] as Map?;
      final native = metadata?['nativeID'] as String? ?? f.id;
      folders[native] = {
        'id': native,
        'name': native == 'unsorted' ? '' : f.name,
        'color': f.color,
      };
    }
    for (final source in sources.values) {
      final id = 'site:${_canonical(source.baseUrl)}';
      folders.putIfAbsent(id, () {
        final color = _nextColor(usedColors);
        usedColors.add(color);
        return {'id': id, 'name': source.name, 'color': color};
      });
    }
    final currentSources = store.sources(AppMode.booru);
    final mapped = {
      for (final source in sources.values)
        source.id:
            currentSources
                .where(
                  (s) => _canonical(s.baseUrl) == _canonical(source.baseUrl),
                )
                .firstOrNull
                ?.id ??
            source.id,
    };
    final currentPosts = store
        .items(AppMode.booru)
        .map((s) => '${s.item.sourceId}:${s.item.id}')
        .toSet();
    final favorites = <Map<String, dynamic>>[], seen = <String>{};
    var duplicates = 0;
    for (final raw in root['favorites'] as List) {
      if (raw is! Map) {
        skipped++;
        continue;
      }
      final id = _int(raw['ppostId']);
      final page = raw['ppostUrl'] is String
          ? Uri.tryParse(raw['ppostUrl'] as String)
          : null;
      if (id == null ||
          id <= 0 ||
          page == null ||
          !['http', 'https'].contains(page.scheme) ||
          page.userInfo.isNotEmpty) {
        skipped++;
        continue;
      }
      final address = _canonical(page);
      final matches =
          sources.values
              .where(
                (s) =>
                    address == _canonical(s.baseUrl) ||
                    address.startsWith('${_canonical(s.baseUrl)}/'),
              )
              .toList()
            ..sort(
              (a, b) => b.baseUrl.path.length.compareTo(a.baseUrl.path.length),
            );
      if (matches.isEmpty) {
        skipped++;
        continue;
      }
      final source = matches.first;
      final key = '${mapped[source.id]}:$id';
      if (!seen.add(key) || currentPosts.contains(key)) {
        duplicates++;
        continue;
      }
      final file = raw['file'] is Map ? raw['file'] as Map : const {};
      final preview = raw['preview'] is Map ? raw['preview'] as Map : const {};
      final sample = raw['sample'] is Map ? raw['sample'] as Map : const {};
      final jpeg = raw['jpeg'] is Map ? raw['jpeg'] as Map : const {};
      final fileUrl = _media(file['url'], source.baseUrl);
      final previewUrl = _media(preview['url'], source.baseUrl);
      final sampleUrl =
          _media(sample['url'], source.baseUrl) ??
          _media(jpeg['url'], source.baseUrl);
      final rating = raw['rating'] as String? ?? '';
      final modern =
          source.kind == SourceKind.danbooru ||
          (source.kind == SourceKind.gelbooru &&
              {
                'gelbooru.com',
                'www.gelbooru.com',
              }.contains(source.baseUrl.host));
      favorites.add({
        'post': {
          'serverID': source.id,
          'postID': id,
          if (previewUrl != null) 'previewURL': previewUrl.toString(),
          if (sampleUrl != null) 'sampleURL': sampleUrl.toString(),
          if (fileUrl != null) 'fileURL': fileUrl.toString(),
          'width': (_int(file['width']) ?? 0).clamp(0, 0x7FFFFFFFFFFFFFFF),
          'height': (_int(file['height']) ?? 0).clamp(0, 0x7FFFFFFFFFFFFFFF),
          'tags': _tokens(raw['tags']),
          'artists': _tokens(raw['tag_artist']),
          'rating': !modern && rating == 's' ? 'g' : rating,
          'score': _int(raw['score']) ?? 0,
          'fileExtension':
              (file['ext'] as String? ?? fileUrl?.path.split('.').last ?? '')
                  .toLowerCase(),
          'poolIDs': [],
        },
        'folderID': 'site:${_canonical(source.baseUrl)}',
        'savedAt': _animeDate(raw['dateAdded']),
      });
    }
    final history = <Map<String, dynamic>>[], tags = <Map<String, dynamic>>[];
    final searches = root['searchHistory'] is List
        ? root['searchHistory'] as List
        : const [];
    for (final row in searches) {
      if (row is! Map ||
          row['searchText'] is! String ||
          (row['searchText'] as String).trim().isEmpty) {
        skipped++;
        continue;
      }
      for (final source in sources.values) {
        history.add({
          'serverID': source.id,
          'query': row['searchText'],
          'usedAt': _animeDate(row['searchDate']),
        });
        if (row['starred'] == true) {
          tags.add({
            'serverID': source.id,
            'name': row['searchText'],
            'kind': 'search',
          });
        }
      }
    }
    final rules = <String>[];
    for (final rule
        in root['bannedTags'] is List ? root['bannedTags'] as List : const []) {
      final text = rule is String
          ? rule
          : rule is Map
          ? rule['tag'] ?? rule['name']
          : null;
      if (text is String && text.isNotEmpty) {
        rules.add(text);
      } else {
        skipped++;
      }
    }
    final blacklists = <String, String>{};
    final oldRules = old['blacklist'] as Map? ?? {};
    for (final source in sources.values) {
      if (rules.isEmpty) continue;
      final previous = oldRules[mapped[source.id]] as String? ?? '';
      blacklists[source.id] = {
        ...previous.split('\n').where((s) => s.isNotEmpty),
        ...rules,
      }.join('\n');
    }
    final envelope = {
      'format': 'tegnal-image-library',
      'version': 1,
      'exportedAt': 0,
      'servers': sources.values.map((s) => s.toJson()).toList(),
      'folders': folders.values.toList(),
      'favorites': favorites,
      'history': history,
      'savedTags': tags,
      'blacklist': blacklists,
      'selectedServerIDs': selected.toList(),
    };
    _codec.inspect(jsonEncode(envelope));
    return _LegacyPlan(
      envelope,
      LegacyImportSummary(
        workCount: favorites.length,
        folderCount: folders.length,
        duplicates: duplicates,
        skipped: skipped,
        serverCount: sources.values
            .where(
              (s) => !currentSources.any(
                (c) => _canonical(c.baseUrl) == _canonical(s.baseUrl),
              ),
            )
            .length,
      ),
    );
  }

  static String? _table(Database db, String name) =>
      db.select(
            'SELECT name FROM sqlite_master WHERE type=? AND lower(name)=lower(?)',
            ['table', name],
          ).firstOrNull?['name']
          as String?;
  static String? _catalogTable(Database db) {
    final tables = db
        .select(
          "SELECT name FROM sqlite_master WHERE type=? AND name NOT LIKE ?",
          ['table', 'sqlite_%'],
        )
        .map((r) => r['name'] as String)
        .toList();
    final preferred = tables.where((t) => t == 'MangaColumnModel').toList();
    final candidates = [
      ...preferred,
      ...tables.where(
        (t) => t.endsWith('ColumnModel') && !preferred.contains(t),
      ),
      ...tables.where((t) => !t.endsWith('ColumnModel')),
    ];
    for (final table in candidates) {
      final columns = db
          .select('PRAGMA table_info(${_quote(table)})')
          .map((r) => (r['name'] as String).toLowerCase())
          .toSet();
      if (columns.containsAll(['id', 'title', 'artists'])) return table;
    }
    return null;
  }

  static String _quote(String identifier) =>
      '"${identifier.replaceAll('"', '""')}"';
  static dynamic _field(Row row, List<String> aliases) {
    for (final name in aliases) {
      final key = row.keys
          .where((key) => key.toLowerCase() == name.toLowerCase())
          .firstOrNull;
      if (key != null && row[key] != null) return row[key];
    }
    return null;
  }

  static int? _int(dynamic value) {
    if (value is int) return value;
    if (value is num && value.isFinite) return value.toInt();
    return value is String ? int.tryParse(value) : null;
  }

  static String? _string(dynamic value) => value is String
      ? value
      : value is num
      ? value.toString()
      : null;
  static String? _piped(String? text) {
    if (text == null) return null;
    final parts = text
        .split('|')
        .map((s) => s.trim())
        .where((s) => s.isNotEmpty && s != 'N/A')
        .toList();
    return parts.isEmpty ? null : parts.join(', ');
  }

  static String? _unescape(String? text) => text
      ?.replaceAll('&amp;', '&')
      .replaceAll('&#39;', "'")
      .replaceAll('&quot;', '"')
      .replaceAll('&lt;', '<')
      .replaceAll('&gt;', '>')
      .replaceAll('&nbsp;', ' ');
  static String? _published(dynamic raw) {
    final integer = _int(raw);
    if (integer != null && (raw is int || integer > 600000000000000000)) {
      if (integer > 621355968000000000) {
        final micros = (integer - 621355968000000000) ~/ 10;
        if (micros <= 8640000000000000000) {
          return DateTime.fromMicrosecondsSinceEpoch(
            micros,
            isUtc: true,
          ).toIso8601String();
        }
      }
      return integer.toString();
    }
    return _string(raw);
  }

  static String? _bookmarkDate(dynamic raw) {
    final text = _string(raw);
    if (text == null) return null;
    final date = DateTime.tryParse(text);
    if (date != null) return date.toUtc().toIso8601String();
    final ticks = _int(raw);
    if (ticks != null && ticks > 621355968000000000) return _published(ticks);
    return null;
  }

  static double _animeDate(dynamic value) => value is String
      ? (DateTime.tryParse(value)?.toUtc().microsecondsSinceEpoch ?? 0) /
            1000000
      : 0;
  static List<String> _tokens(dynamic value) => value is List
      ? value.whereType<String>().toList()
      : value is String
      ? value.split(RegExp(r'\s+')).where((v) => v.isNotEmpty).toList()
      : [];
  static Uri? _media(dynamic raw, Uri base) {
    if (raw is! String || raw.isEmpty) return null;
    final uri = base.resolve(raw);
    if (!['http', 'https'].contains(uri.scheme) ||
        uri.host.isEmpty ||
        uri.userInfo.isNotEmpty) {
      return null;
    }
    return uri.replace(scheme: 'https');
  }

  static String _canonical(Uri uri) {
    var host = uri.host.toLowerCase();
    if ({
      'www.gelbooru.com',
      'www.safebooru.org',
      'www.danbooru.donmai.us',
    }.contains(host)) {
      host = host.substring(4);
    }
    return Uri(
      scheme: 'https',
      host: host,
      port: uri.hasPort && uri.port != 443 ? uri.port : null,
      path: uri.path
          .replaceFirst(RegExp(r'/index\.php/?$'), '')
          .replaceFirst(RegExp(r'/+$'), ''),
    ).toString();
  }

  static int _nextColor(Set<int> used) {
    for (final color in _palette) {
      if (!used.contains(color)) return color;
    }
    var color = 0xFF000000 | ((used.length * 2654435761) & 0xFFFFFF);
    while (used.contains(color)) {
      color = 0xFF000000 | ((color + 0x9E3779) & 0xFFFFFF);
    }
    return color;
  }

  static void _checkCancel(bool Function()? canceled) {
    if (canceled?.call() == true) throw const LegacyImportCancelled();
  }

  static void _require(bool value, String message) {
    if (!value) throw FormatException(message);
  }
}

class _LegacyPlan {
  const _LegacyPlan(this.envelope, this.summary);
  final Map<String, dynamic> envelope;
  final LegacyImportSummary summary;
}
