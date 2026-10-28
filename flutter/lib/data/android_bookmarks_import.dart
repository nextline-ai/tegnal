import 'dart:convert';
import 'dart:io';
import 'dart:isolate';

import 'package:crypto/crypto.dart';
import 'package:sqlite3/sqlite3.dart';

import '../core/content.dart';
import '../core/library.dart';
import 'legacy_import.dart';
import 'library_store.dart';

class AndroidBookmarksSummary extends LegacyImportSummary {
  const AndroidBookmarksSummary({
    super.workCount,
    super.folderCount,
    super.artistCount,
    super.duplicates,
    super.skipped,
    this.readLogCount = 0,
    this.searchCount = 0,
    this.cropCount = 0,
    this.preservedRecordCount = 0,
    this.unsupportedDownloadCount = 0,
  });
  final int readLogCount, searchCount, cropCount, preservedRecordCount;
  final int unsupportedDownloadCount;
}

/// Android bookmark backups are distinct from the older user.db/catalog path.
/// Parsing and staging run off the UI isolate; the live merge is bulk SQL and
/// atomic. Source databases are only opened read-only, never attached writable.
class AndroidBookmarksImport {
  AndroidBookmarksImport(this.store);
  final LibraryStore store;

  Future<AndroidBookmarksSummary> inspectFile(String path) =>
      _withStage(path, (stage) => _summary(stage));

  Future<AndroidBookmarksSummary> importFile(
    String path, {
    bool Function()? isCancelled,
    void Function(int)? onProgress,
  }) => _withStage(path, (stage) {
    _cancel(isCancelled);
    final summary = _summary(stage);
    onProgress?.call(summary.preservedRecordCount);
    _cancel(isCancelled);
    _merge(stage, isCancelled);
    return summary;
  }, isCancelled: isCancelled);

  Future<T> _withStage<T>(
    String path,
    T Function(Database) use, {
    bool Function()? isCancelled,
  }) async {
    _cancel(isCancelled);
    final file = File(path);
    if (await file.length() > 256 * 1024 * 1024) {
      throw const FormatException(
        'Android bookmarks database exceeds 256 MiB.',
      );
    }
    final directory = await Directory.systemTemp.createTemp(
      'tegnal-bookmarks-',
    );
    final sourcePath = file.absolute.path;
    final stagingPath = '${directory.path}/stage.sqlite';
    Database? staging;
    try {
      await Isolate.run(() => _stageAndroid(sourcePath, stagingPath));
      _cancel(isCancelled);
      staging = sqlite3.open(stagingPath, mode: OpenMode.readOnly);
      return use(staging);
    } finally {
      staging?.close();
      await directory.delete(recursive: true);
    }
  }

  AndroidBookmarksSummary _summary(Database stage) {
    int count(String table) =>
        stage.select('SELECT COUNT(*) AS n FROM $table').single['n'] as int;
    final sourceCounts = {
      for (final row in stage.select('SELECT * FROM counts'))
        row['name'] as String: row['count'] as int,
    };
    var duplicates = sourceCounts['duplicates'] ?? 0;
    // One indexed SQL join avoids a UI-isolate query for every bookmarked ID.
    final stagePath = stage.select('PRAGMA database_list').single['file'];
    store.database.execute('ATTACH DATABASE ? AS android_bookmark_preview', [
      stagePath,
    ]);
    try {
      duplicates +=
          store.database.select('''
        SELECT COUNT(*) AS n FROM android_bookmark_preview.works w
        JOIN items i ON i.key='manga:'||w.id
      ''').single['n']
              as int;
    } finally {
      store.database.execute('DETACH DATABASE android_bookmark_preview');
    }
    return AndroidBookmarksSummary(
      workCount: count('works'),
      folderCount: count('groups'),
      artistCount: count('artists'),
      duplicates: duplicates,
      skipped: sourceCounts['skipped'] ?? 0,
      readLogCount: sourceCounts['ArticleReadLog'] ?? 0,
      searchCount: sourceCounts['SearchLog'] ?? 0,
      cropCount: sourceCounts['BookmarkCropImage'] ?? 0,
      preservedRecordCount: count('records'),
      unsupportedDownloadCount: sourceCounts['DownloadItem'] ?? 0,
    );
  }

  void _merge(Database stage, bool Function()? cancelled) {
    final stagePath =
        stage.select('PRAGMA database_list').single['file'] as String;
    final db = store.database;
    final archived = (store.setting('archivedSources', <String>[]) as List)
        .toSet();
    final available = store
        .sources(AppMode.manga)
        .where((s) => !archived.contains(s.id));
    final selected = store.setting('source.manga');
    final sourceId =
        available.where((s) => s.id == selected).firstOrNull?.id ??
        available.firstOrNull?.id ??
        '';
    db.execute('ATTACH DATABASE ? AS android_bookmark_stage', [stagePath]);
    try {
      store.transaction(() {
        _cancel(cancelled);
        db.execute(
          'CREATE TEMP TABLE android_bookmark_groups(native_id INTEGER PRIMARY KEY,folder_id TEXT NOT NULL)',
        );
        db.execute(
          'CREATE TEMP TABLE android_bookmark_new(id INTEGER PRIMARY KEY)',
        );
        final existingFolders = store.folders(AppMode.manga);
        final used = store.folders(AppMode.booru).map((f) => f.id).toSet()
          ..addAll(existingFolders.map((f) => f.id));
        var position =
            existingFolders.fold<int>(
              -1,
              (last, f) => f.position > last ? f.position : last,
            ) +
            1;
        for (final row in stage.select(
          'SELECT * FROM groups ORDER BY position,id',
        )) {
          final name = row['name'] as String;
          final identity = sha256.convert(utf8.encode(name)).toString();
          final registry = 'legacy.androidBookmarks.folder.$identity';
          final priorId = store.portable(registry)?['folderID'];
          final previous =
              existingFolders.where((f) => f.id == priorId).firstOrNull ??
              existingFolders.where((f) => f.name == name).firstOrNull;
          var id = previous?.id ?? 'manga:android:$identity';
          if (previous == null) {
            var suffix = 1;
            final base = id;
            while (!used.add(id)) {
              id = '$base-${suffix++}';
            }
            final folder = LibraryFolder(
              id: id,
              mode: AppMode.manga,
              name: name,
              color: row['color'] as int,
              position: position++,
            );
            store.saveFolder(folder);
            existingFolders.add(folder);
          }
          store.setPortable(registry, {'folderID': id});
          db.execute('INSERT INTO android_bookmark_groups VALUES (?,?)', [
            row['id'],
            id,
          ]);
        }
        _cancel(cancelled);
        db.execute('''
          INSERT INTO android_bookmark_new
          SELECT id FROM android_bookmark_stage.works w
          WHERE NOT EXISTS(SELECT 1 FROM items i WHERE i.key='manga:'||w.id)
        ''');
        db.execute(
          '''
          INSERT INTO items(key,mode,payload,saved_at,note)
          SELECT 'manga:'||w.id,'manga',json_set(w.payload,'\$.sourceId',?),w.saved_at,''
          FROM android_bookmark_stage.works w JOIN android_bookmark_new n ON n.id=w.id
        ''',
          [sourceId],
        );
        // Existing work metadata, notes, dates, progress and folder choices win.
        db.execute('''
          INSERT OR IGNORE INTO memberships(item_key,folder_id)
          SELECT 'manga:'||m.work_id,g.folder_id
          FROM android_bookmark_stage.memberships m
          JOIN android_bookmark_new n ON n.id=m.work_id
          JOIN android_bookmark_groups g ON g.native_id=m.group_id
        ''');
        _cancel(cancelled);
        final existingArtists = store
            .artists(AppMode.manga)
            .map((a) => '${a.kind}:${a.name}')
            .toSet();
        final insertArtist = db.prepare(
          'INSERT OR IGNORE INTO artists VALUES (?,?,?)',
        );
        try {
          for (final row in stage.select('SELECT * FROM artists')) {
            final name = row['name'] as String;
            final kind = row['kind'] as int;
            if (!existingArtists.add('$kind:$name')) continue;
            final artist = ArtistEntry(
              name: name,
              mode: AppMode.manga,
              sourceId: sourceId,
              kind: kind,
            );
            insertArtist.execute([
              'manga:$sourceId:$kind:$name',
              'manga',
              jsonEncode(artist.toJson()),
            ]);
          }
        } finally {
          insertArtist.close();
        }
        db.execute(
          '''
          INSERT OR IGNORE INTO history(mode,source_id,query,used_at)
          SELECT 'manga',?,query,used_at FROM android_bookmark_stage.history
        ''',
          [sourceId],
        );
        _cancel(cancelled);
        // Raw import evidence is local-only portable data. BackupCodec does not
        // export legacy.* records; opaque crop/read fields aren't misinterpreted.
        db.execute(
          'INSERT OR IGNORE INTO portable SELECT key,payload FROM android_bookmark_stage.records',
        );
        db.execute('DROP TABLE android_bookmark_new');
        db.execute('DROP TABLE android_bookmark_groups');
        _cancel(cancelled);
      });
    } finally {
      db.execute('DROP TABLE IF EXISTS temp.android_bookmark_new');
      db.execute('DROP TABLE IF EXISTS temp.android_bookmark_groups');
      db.execute('DETACH DATABASE android_bookmark_stage');
    }
  }

  static void _cancel(bool Function()? cancelled) {
    if (cancelled?.call() == true) throw const LegacyImportCancelled();
  }
}

const _schemaError = FormatException(
  'Choose an Android bookmarks SQLite database.',
);

void _stageAndroid(String sourcePath, String stagePath) {
  final source = sqlite3.open(sourcePath, mode: OpenMode.readOnly);
  Database? stage;
  try {
    source.execute('BEGIN');
    final tables = {
      for (final row in source.select(
        "SELECT name FROM sqlite_master WHERE type='table'",
      ))
        (row['name'] as String).toLowerCase(): row['name'] as String,
    };
    for (final (name, columns) in const [
      ('android_metadata', ['locale']),
      ('BookmarkGroup', ['Id', 'Name', 'Color', 'Gorder']),
      ('BookmarkArticle', ['Id', 'Article', 'DateTime', 'GroupId']),
      ('BookmarkArtist', ['Artist', 'IsGroup']),
      ('ArticleReadLog', ['Article', 'LastPage']),
      ('BookmarkCropImage', ['Article', 'Page', 'Area']),
      ('SearchLog', ['SearchWhat', 'DateTime']),
    ]) {
      final table = tables[name.toLowerCase()];
      if (table == null) throw _schemaError;
      final actual = source
          .select('PRAGMA table_info(${_quote(table)})')
          .map((r) => (r['name'] as String).toLowerCase())
          .toSet();
      if (!columns.every((c) => actual.contains(c.toLowerCase()))) {
        throw _schemaError;
      }
    }
    stage = sqlite3.open(stagePath);
    stage.execute('''
      CREATE TABLE groups(id INTEGER PRIMARY KEY,name TEXT NOT NULL,color INTEGER NOT NULL,position INTEGER NOT NULL,is_default INTEGER NOT NULL);
      CREATE TABLE works(id INTEGER PRIMARY KEY,payload TEXT NOT NULL,saved_at TEXT NOT NULL);
      CREATE TABLE memberships(work_id INTEGER NOT NULL,group_id INTEGER NOT NULL,PRIMARY KEY(work_id,group_id));
      CREATE TABLE artists(name TEXT NOT NULL,kind INTEGER NOT NULL,PRIMARY KEY(name,kind));
      CREATE TABLE history(query TEXT PRIMARY KEY,used_at TEXT NOT NULL);
      CREATE TABLE records(key TEXT PRIMARY KEY,payload TEXT NOT NULL);
      CREATE TABLE counts(name TEXT PRIMARY KEY,count INTEGER NOT NULL);
    ''');
    stage.execute('BEGIN');
    var skipped = 0, duplicates = 0, total = 0;
    final groupIds = <int>{};
    for (final name in const [
      'BookmarkGroup',
      'BookmarkArticle',
      'BookmarkArtist',
      'ArticleReadLog',
      'BookmarkCropImage',
      'SearchLog',
      'BookmarkUser',
      'HistoryUser',
    ]) {
      final table = tables[name.toLowerCase()];
      if (table == null) continue;
      int? cursor;
      var count = 0;
      while (true) {
        final rows = source.select(
          'SELECT rowid AS _import_rowid,* FROM ${_quote(table)} WHERE (? IS NULL OR rowid>?) ORDER BY rowid LIMIT 500',
          [cursor, cursor],
        );
        if (rows.isEmpty) break;
        for (final row in rows) {
          cursor = row['_import_rowid'] as int;
          count++;
          if (++total > 1000000) {
            throw const FormatException(
              'Android bookmarks database has too many records.',
            );
          }
          final fields = <String, dynamic>{
            for (final key in row.keys)
              if (key != '_import_rowid') key: row[key],
          };
          final raw = jsonEncode({
            'format': 'android-bookmarks',
            'table': name,
            'record': fields,
          });
          final digest = sha256.convert(utf8.encode(raw));
          stage.execute('INSERT OR IGNORE INTO records VALUES (?,?)', [
            'legacy.androidBookmarks.record.$digest',
            raw,
          ]);
          dynamic field(String key) => fields.entries
              .where((e) => e.key.toLowerCase() == key.toLowerCase())
              .firstOrNull
              ?.value;
          if (name == 'BookmarkGroup') {
            final id = _integer(field('Id'));
            var label = field('Name');
            if (id == null || label is! String || label.trim().isEmpty) {
              skipped++;
              continue;
            }
            final defaultGroup =
                (id == 0 || id == 1) && label.endsWith('_default');
            if (defaultGroup) label = '미분류';
            final rawColor = _integer(field('Color'));
            final color =
                rawColor != null &&
                    rawColor >= -0x80000000 &&
                    rawColor <= 0xffffffff
                ? rawColor & 0xffffffff
                : 0;
            stage.execute('INSERT OR IGNORE INTO groups VALUES (?,?,?,?,?)', [
              id,
              label,
              color == 0 ? 0xff5e5ce6 : color,
              _integer(field('Gorder')) ?? count,
              defaultGroup ? 1 : 0,
            ]);
            groupIds.add(id);
          } else if (name == 'BookmarkArticle') {
            final id = _articleId(field('Article'));
            if (id == null) {
              skipped++;
              continue;
            }
            if (stage.select('SELECT 1 FROM works WHERE id=?', [
              id,
            ]).isNotEmpty) {
              duplicates++;
            }
            final item = ContentItem(
              sourceId: '',
              id: id,
              mode: AppMode.manga,
              title: '#$id',
              metadata: {
                'metadata_source': 'android-bookmarks',
                'nativeBackup': {'gallery_id': id},
              },
            );
            stage.execute(
              'INSERT INTO works VALUES (?,?,?) ON CONFLICT(id) DO UPDATE SET saved_at=MAX(saved_at,excluded.saved_at)',
              [id, jsonEncode(item.toJson()), _date(field('DateTime'))],
            );
            final group = _integer(field('GroupId'));
            if (group != null && groupIds.contains(group)) {
              stage.execute('INSERT OR IGNORE INTO memberships VALUES (?,?)', [
                id,
                group,
              ]);
            }
          } else if (name == 'BookmarkArtist') {
            final name = field('Artist');
            if (name is! String || name.trim().isEmpty) {
              skipped++;
              continue;
            }
            stage.execute('INSERT OR IGNORE INTO artists VALUES (?,?)', [
              name,
              _integer(field('IsGroup')) == 1 ? 1 : 0,
            ]);
          } else if (name == 'SearchLog') {
            final query = field('SearchWhat');
            if (query is! String || query.trim().isEmpty) {
              skipped++;
              continue;
            }
            stage.execute(
              'INSERT INTO history VALUES (?,?) ON CONFLICT(query) DO UPDATE SET used_at=MAX(used_at,excluded.used_at)',
              [query, _date(field('DateTime'))],
            );
          }
        }
      }
      stage.execute('INSERT INTO counts VALUES (?,?)', [name, count]);
    }
    // Named assignments take priority over the source's default association.
    stage.execute(
      '''DELETE FROM memberships WHERE group_id IN (SELECT id FROM groups WHERE is_default=1)
      AND work_id IN(SELECT m.work_id FROM memberships m JOIN groups g ON g.id=m.group_id WHERE g.is_default=0)''',
    );
    final downloads = tables['downloaditem'];
    final downloadCount = downloads == null
        ? 0
        : source
                  .select('SELECT COUNT(*) AS n FROM ${_quote(downloads)}')
                  .single['n']
              as int;
    stage.execute('INSERT INTO counts VALUES (?,?),(?,?),(?,?)', [
      'skipped',
      skipped,
      'duplicates',
      duplicates,
      'DownloadItem',
      downloadCount,
    ]);
    stage.execute('COMMIT');
  } finally {
    stage?.close();
    source.close();
  }
}

String _quote(String text) => '"${text.replaceAll('"', '""')}"';
int? _integer(dynamic raw) => raw is int
    ? raw
    : raw is String
    ? int.tryParse(raw)
    : null;
int? _articleId(dynamic raw, [int depth = 0]) {
  final number = _integer(raw);
  if (number != null) return number > 0 ? number : null;
  if (depth > 2) return null;
  if (raw is String) {
    try {
      return _articleId(jsonDecode(raw), depth + 1);
    } on FormatException {
      return null;
    }
  }
  if (raw is Map) {
    for (final entry in raw.entries) {
      if ({
        'id',
        'galleryid',
        'gallery_id',
        'article',
      }.contains(entry.key.toString().toLowerCase())) {
        final id = _articleId(entry.value, depth + 1);
        if (id != null) return id;
      }
    }
  }
  return null;
}

String _date(dynamic raw) {
  final text = raw?.toString();
  final ticks = _integer(raw);
  if (ticks != null &&
      ticks > 621355968000000000 &&
      ticks < 3155378976000000000) {
    return DateTime.fromMicrosecondsSinceEpoch(
      (ticks - 621355968000000000) ~/ 10,
      isUtc: true,
    ).toIso8601String();
  }
  return (text == null ? null : DateTime.tryParse(text))
          ?.toUtc()
          .toIso8601String() ??
      '1970-01-01T00:00:00.000Z';
}
