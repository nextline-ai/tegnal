import '../../domain/models.dart';
import '../storage/app_database.dart';
import '../support/l10n.dart';
import '../support/sql_database.dart';
import '../support/swift_json.dart';

/// What an import brought in.
class ImportSummary {
  const ImportSummary({this.folders = 0, this.works = 0, this.catalog = 0, this.titlesFilled = 0, this.titlesMissing = 0, this.artists = 0});
  final int folders;
  final int works;
  final int catalog;
  final int titlesFilled;
  final int titlesMissing;
  final int artists;
}

/// `MangaViewerImportService`: bookmarks, folders and artists from another manga viewer's
/// user database, and work information from its catalog database. Both are only read.
class MangaViewerImportService {
  MangaViewerImportService(this.database);
  final AppDatabase database;

  static SqlDatabase openReadOnly(String path) => SqlDatabase.openReadOnly(path);

  static bool isUserDatabase(String path) => _probe(path, (db) => db.tableExists('BookmarkArticle'));
  static bool isDataDatabase(String path) => _probe(path, (db) => _catalogTable(db) != null);

  static bool _probe(String path, bool Function(SqlDatabase db) test) {
    SqlDatabase? db;
    try {
      db = openReadOnly(path);
      return test(db);
    } on Object {
      return false;
    } finally {
      db?.close();
    }
  }

  static String? _catalogTable(SqlDatabase db) {
    if (db.tableExists('MangaColumnModel')) return 'MangaColumnModel';
    final tables = db.column<String>("SELECT name FROM sqlite_master WHERE type='table' AND name NOT LIKE 'sqlite_%'");
    for (final table in tables) {
      if (table.endsWith('ColumnModel')) return table;
    }
    for (final table in tables) {
      final columns = db.columns(table);
      if (columns.contains('Id') && columns.contains('Title') && columns.contains('Artists')) return table;
    }
    return null;
  }

  // Columns hold mixed types in these databases; never assume one.
  static String? _string(Map<String, Object?> row, String column) => switch (row[column]) {
    final String text => text,
    final int number => '$number',
    final double number => '$number',
    _ => null,
  };

  static int? _int(Map<String, Object?> row, String column) => switch (row[column]) {
    final int number => number,
    final String text => int.tryParse(text),
    final double number => number.toInt(),
    _ => null,
  };

  static String? _published(Map<String, Object?> row) {
    final value = row['Published'];
    switch (value) {
      case final int ticks:
        return _ticks(ticks);
      case final String text:
        final ticks = int.tryParse(text);
        return ticks != null && ticks > 600000000000000000 ? _ticks(ticks) : text;
      case final double number:
        final ticks = number.toInt();
        return ticks > 600000000000000000 ? _ticks(ticks) : '$number';
      default:
        return null;
    }
  }

  /// .NET ticks (100 ns since year 1) as an ISO 8601 date.
  static String _ticks(int ticks) {
    const epochTicks = 621355968000000000;
    if (ticks <= epochTicks) return '$ticks';
    return iso8601(DateTime.fromMicrosecondsSinceEpoch((ticks - epochTicks) ~/ 10, isUtc: true));
  }

  static String? _piped(String? raw) {
    if (raw == null || raw.isEmpty) return null;
    final parts = raw.split('|').map((part) => part.trim()).where((part) => part.isNotEmpty && part != 'N/A').toList();
    return parts.isEmpty ? null : parts.join(', ');
  }

  static String? _unescape(String? text) => text
      ?.replaceAll('&amp;', '&')
      .replaceAll('&#39;', "'")
      .replaceAll('&quot;', '"')
      .replaceAll('&lt;', '<')
      .replaceAll('&gt;', '>')
      .replaceAll('&nbsp;', ' ');

  static CatalogWork? _catalog(Map<String, Object?> row) {
    final id = _int(row, 'Id');
    if (id == null) return null;
    return CatalogWork(
      id: id,
      title: _unescape(_string(row, 'Title')),
      type: _string(row, 'Type'),
      language: _string(row, 'Language'),
      artists: _piped(_string(row, 'Artists')),
      groups: _piped(_string(row, 'Groups')),
      series: _piped(_string(row, 'Series')),
      characters: _piped(_string(row, 'Characters')),
      tags: _piped(_string(row, 'Tags')),
      published: _published(row),
    );
  }

  /// Folders, bookmarked works and favorite artists from the user database.
  ({int folders, int works, int artists}) importUserDatabase(String path, {bool Function()? cancelled}) {
    void check() {
      if (cancelled?.call() ?? false) throw const ImportCancelled();
    }

    check();
    final source = openReadOnly(path);
    late final List<Map<String, Object?>> groups, articles, artistRows;
    try {
      // Read one consistent snapshot of the source.
      groups = source.rows('SELECT * FROM BookmarkGroup ORDER BY Gorder ASC, Id ASC');
      articles = source.rows('SELECT * FROM BookmarkArticle ORDER BY DateTime DESC, Id DESC');
      artistRows = source.tableExists('BookmarkArtist') ? source.rows('SELECT * FROM BookmarkArtist') : const [];
    } finally {
      source.close();
    }
    var folderCount = 0, workCount = 0, artistCount = 0;
    final groupMap = <int, int>{};
    final assignedColors = <int>{};
    for (final group in groups) {
      check();
      final sourceGroupId = _int(group, 'Id') ?? _int(group, 'id');
      if (sourceGroupId == null) continue;
      var name = _string(group, 'Name') ?? _string(group, 'name') ?? L10n.text('Folders');
      final rawColor = _int(group, 'Color') ?? _int(group, 'color');
      if ((sourceGroupId == 0 || sourceGroupId == 1) && name.endsWith('_default')) name = '미분류';
      final color = rawColor != null && rawColor != 4294940672 && rawColor != 0 && !assignedColors.contains(rawColor)
          ? rawColor
          : database.nextUniqueFolderColor(excluding: assignedColors);
      assignedColors.add(color);
      final folder = database.createFolder(name: name, description: _string(group, 'Description'), color: color, sourceGroupId: sourceGroupId);
      if (folder.id case final id?) {
        groupMap[sourceGroupId] = id;
        folderCount += 1;
      }
    }
    check();
    final defaultFolderId = database.ensureDefaultFolder().id ?? 1;
    groupMap.putIfAbsent(1, () => defaultFolderId);
    groupMap.putIfAbsent(0, () => defaultFolderId);
    for (final article in articles) {
      check();
      final galleryId = _int(article, 'Article') ?? _int(article, 'article') ?? _int(article, 'GalleryId') ?? _int(article, 'Id');
      if (galleryId == null) continue;
      final rawGroupId = _int(article, 'GroupId') ?? _int(article, 'group_id') ?? _int(article, 'Group');
      final folderId = (rawGroupId == null ? null : groupMap[rawGroupId]) ?? defaultFolderId;
      final catalog = database.getCatalog(galleryId);
      database.upsertWork(
        galleryId: galleryId,
        folderId: folderId,
        title: catalog?.title,
        artists: catalog?.artists,
        language: catalog?.language,
        type: catalog?.type,
        series: catalog?.series,
        groups: catalog?.groups,
        tags: catalog?.tags,
        publishedAt: catalog?.published,
        bookmarkedAt: _string(article, 'DateTime'),
        metadataSource: catalog != null ? 'catalog' : null,
        catalogMatched: catalog != null,
      );
      workCount += 1;
    }
    check();
    // Works filed elsewhere leave the default folder.
    try {
      database.dbWriter.write(
        (db) => db.execute('DELETE FROM folder_works WHERE folder_id = ? AND work_id IN (SELECT work_id FROM folder_works WHERE folder_id != ?)', [
          defaultFolderId,
          defaultFolderId,
        ]),
      );
    } on Object {
      // Pruning is cosmetic; the import already succeeded.
    }
    for (final row in artistRows) {
      check();
      final name = _string(row, 'Artist');
      if (name == null || name.isEmpty) continue;
      database.addFavoriteArtist(name, kind: _int(row, 'IsGroup') ?? 0);
      artistCount += 1;
    }
    check();
    return (folders: folderCount, works: workCount, artists: artistCount);
  }

  /// Fills only the library's own works from a catalog database.
  ({int matched, int totalWorks}) matchAndFillWorks(String path, {bool Function()? cancelled}) {
    final targets = database.listAllGalleryIds();
    if (targets.isEmpty) return (matched: 0, totalWorks: 0);
    final source = openReadOnly(path);
    try {
      final table = _catalogTable(source);
      if (table == null) throw const ImportFormatError();
      var matched = 0;
      for (var start = 0; start < targets.length; start += 400) {
        if (cancelled?.call() ?? false) throw const ImportCancelled();
        final chunk = targets.sublist(start, start + 400 > targets.length ? targets.length : start + 400);
        final rows = source.rows(
          'SELECT Id, Title, Type, Artists, Characters, Groups, Language, Series, Tags, Published FROM $table WHERE Id IN (${List.filled(chunk.length, '?').join(',')})',
          chunk,
        );
        final batch = [for (final row in rows) ?_catalog(row)];
        if (batch.isNotEmpty) matched += database.applyCatalogBatchToWorks(batch);
      }
      return (matched: matched, totalWorks: targets.length);
    } finally {
      source.close();
    }
  }

  /// The whole catalog, a page at a time, then applied to the library.
  int importDataDatabase(String path, {void Function(int count)? progress, bool Function()? cancelled}) {
    final source = openReadOnly(path);
    try {
      final table = _catalogTable(source);
      if (table == null) throw const ImportFormatError();
      var lastId = 0, total = 0;
      while (true) {
        if (cancelled?.call() ?? false) throw const ImportCancelled();
        final chunk = source.rows(
          'SELECT Id, Title, Type, Artists, Characters, Groups, Language, Series, Tags, Published FROM $table WHERE Id > ? ORDER BY Id ASC LIMIT 1000',
          [lastId],
        );
        if (chunk.isEmpty) break;
        final batch = <CatalogWork>[];
        for (final row in chunk) {
          final work = _catalog(row);
          if (work == null) continue;
          lastId = work.id;
          batch.add(work);
        }
        if (batch.isEmpty) break;
        database.upsertCatalogBatch(batch);
        total += batch.length;
        progress?.call(total);
      }
      database.applyCatalogToWorks();
      return total;
    } finally {
      source.close();
    }
  }
}

class ImportCancelled implements Exception {
  const ImportCancelled();
}

/// The chosen database has no catalog table.
class ImportFormatError implements Exception {
  const ImportFormatError();
  @override
  String toString() => 'Catalog table not found';
}
