import '../storage/app_database.dart';
import '../support/sql_database.dart';
import '../support/swift_json.dart';
import 'manga_viewer_import.dart';

/// What a Violet backup brought in.
class VioletImportResult {
  const VioletImportResult({this.folders = 0, this.works = 0, this.artists = 0, this.opened = 0});
  final int folders;
  final int works;
  final int artists;

  /// Saved works whose last reading time came from the backup's reading log.
  final int opened;
}

/// Reads the bookmark backup Violet exports on Android: its groups become folders, its
/// bookmarked works are saved into them, bookmarked artists, groups, series and characters
/// become saved collections, and the reading log sets when each saved work was last opened.
/// The backup holds no work information; the cover queue fills titles, tags and covers from
/// the connected website afterwards. The file is only read.
class VioletImportService {
  VioletImportService(this.database);
  final AppDatabase database;

  /// Violet's own unclassified group, which becomes the library's default folder.
  static const _defaultGroupSuffix = '_default';

  static const _chunk = 50;

  /// The color Violet gives every new group; such groups take the next unused folder color.
  static const _newGroupColor = 0xFFFF9800;

  /// Descriptions Violet fills in for groups the person never described.
  static const _placeholderDescriptions = {'새로운 그룹', 'New Group', 'new group', '新しいグループ', 'Unclassified bookmarks.'};

  /// A backup holds Violet's bookmark tables and no work catalog.
  static bool isBackup(String path) {
    SqlDatabase? db;
    try {
      db = SqlDatabase.openReadOnly(path);
      return db.tableExists('BookmarkGroup') && db.tableExists('BookmarkArticle');
    } on Object {
      return false;
    } finally {
      db?.close();
    }
  }

  static String? _string(Object? value) => switch (value) {
    final String text => text,
    final int number => '$number',
    _ => null,
  };

  static int? _int(Object? value) => switch (value) {
    final int number => number,
    final String text => int.tryParse(text.trim()),
    final double number => number.toInt(),
    _ => null,
  };

  /// Violet writes local times such as `2024-04-29 23:47:23.370404`; the library keeps UTC.
  static String? date(Object? value) {
    final text = _string(value)?.trim();
    if (text == null || text.isEmpty) return null;
    final parsed = DateTime.tryParse(text);
    return parsed == null ? null : iso8601(parsed);
  }

  /// Violet's artist types: artist, group, uploader, series and character. The library has
  /// no uploader collection, so those stay behind.
  static int? collectionKind(int? type) => switch (type ?? 0) {
    0 => 0,
    1 => 1,
    3 => 3,
    4 => 4,
    _ => null,
  };

  /// Imports [path], yielding now and then so progress shows and [cancelled] is honored.
  /// Cancelling stops before the next write; what was already saved stays.
  Future<VioletImportResult> import(String path, {bool Function()? cancelled, void Function(int done, int total)? progress}) async {
    void check() {
      if (cancelled?.call() ?? false) throw const ImportCancelled();
    }

    check();
    final source = SqlDatabase.openReadOnly(path);
    late final List<Map<String, Object?>> groups, articles, artistRows, reads;
    try {
      if (!source.tableExists('BookmarkGroup') || !source.tableExists('BookmarkArticle')) throw const VioletFormatError();
      // One consistent snapshot of the backup.
      groups = source.rows('SELECT * FROM BookmarkGroup ORDER BY Gorder ASC, Id ASC');
      articles = source.rows('SELECT * FROM BookmarkArticle ORDER BY DateTime ASC, Id ASC');
      artistRows = source.tableExists('BookmarkArtist') ? source.rows('SELECT * FROM BookmarkArtist ORDER BY DateTime ASC, Id ASC') : const [];
      reads = source.tableExists('ArticleReadLog')
          ? source.rows('SELECT Article, MAX(COALESCE(NULLIF(DateTimeEnd, \'\'), DateTimeStart)) AS Opened FROM ArticleReadLog GROUP BY Article')
          : const [];
    } finally {
      source.close();
    }

    final defaultFolderId = database.ensureDefaultFolder().id ?? 1;
    final folderIds = <int, int>{};
    final assignedColors = <int>{};
    var folderCount = 0;
    for (final group in groups) {
      check();
      final id = _int(group['Id']);
      if (id == null) continue;
      final name = _string(group['Name'])?.trim() ?? '';
      if (name.endsWith(_defaultGroupSuffix) || name.isEmpty) {
        folderIds[id] = defaultFolderId;
        continue;
      }
      final rawColor = _int(group['Color']);
      final color = rawColor != null && rawColor != _newGroupColor && rawColor != 0 && !assignedColors.contains(rawColor)
          ? rawColor
          : database.nextUniqueFolderColor(excluding: assignedColors);
      assignedColors.add(color);
      final description = _string(group['Description'])?.trim();
      final folder = database.createFolder(
        name: name,
        description: description == null || description.isEmpty || _placeholderDescriptions.contains(description) ? null : description,
        color: color,
      );
      if (folder.id case final folderId?) {
        folderIds[id] = folderId;
        folderCount += 1;
      }
    }

    final total = articles.length;
    final saved = <int>{};
    // A few dozen works per transaction, with a frame between them for progress and Cancel.
    for (var start = 0; start < total; start += _chunk) {
      progress?.call(start, total);
      await Future<void>.delayed(Duration.zero);
      check();
      database.dbWriter.write((_) {
        for (final article in articles.skip(start).take(_chunk)) {
          final galleryId = _int(article['Article']);
          if (galleryId == null || galleryId <= 0) continue;
          final groupId = _int(article['GroupId']);
          database.upsertWork(
            galleryId: galleryId,
            folderId: (groupId == null ? null : folderIds[groupId]) ?? defaultFolderId,
            bookmarkedAt: date(article['DateTime']),
          );
          saved.add(galleryId);
        }
      });
    }
    progress?.call(total, total);
    // Works filed in a group as well as Violet's unclassified one leave the default folder.
    database.ensureDefaultFolder();

    var artistCount = 0;
    for (final row in artistRows) {
      check();
      final name = _string(row['Artist'])?.trim() ?? '';
      final kind = collectionKind(_int(row['IsGroup']));
      if (name.isEmpty || kind == null) continue;
      database.addFavoriteArtist(name, kind: kind);
      artistCount += 1;
    }

    check();
    var opened = 0;
    final openedAt = <(String, int)>[
      for (final row in reads)
        if ((_int(row['Article']), date(row['Opened'])) case (final int id, final String at) when saved.contains(id)) (at, id),
    ];
    if (openedAt.isNotEmpty) {
      database.dbWriter.write((db) {
        for (final (at, id) in openedAt) {
          db.execute('UPDATE works SET last_opened_at = ? WHERE gallery_id = ? AND (last_opened_at IS NULL OR last_opened_at < ?)', [at, id, at]);
          opened += db.changesCount;
        }
      });
    }
    return VioletImportResult(folders: folderCount, works: saved.length, artists: artistCount, opened: opened);
  }
}

/// The chosen file is not a Violet bookmark backup.
class VioletFormatError implements Exception {
  const VioletFormatError();
  @override
  String toString() => 'Not a Violet bookmark backup';
}
