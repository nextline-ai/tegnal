import 'dart:io';

import '../../domain/models.dart';
import '../content/manga_urls.dart';
import '../support/l10n.dart';
import '../support/preferences.dart';
import '../support/sql_database.dart';
import '../support/swift_json.dart';
import '../taste/taste_models.dart';
import '../taste/taste_store.dart';
import 'app_storage.dart';
import 'local_thumbnail_cache.dart';
import 'folder_rules.dart';
import 'work_query.dart';

class FolderDeletionError implements Exception {
  const FolderDeletionError();
  String get errorDescription => L10n.text('Move or remove the works in Uncategorized before deleting it.');
}

/// The comics library. Same tables, columns and migration names as the native `memo.sqlite`.
class AppDatabase implements SmartFolderLibrary {
  AppDatabase(this.dbWriter, {required this.preferences}) {
    _migrator.migrate(dbWriter);
  }

  final SqlDatabase dbWriter;
  final AppPreferences preferences;

  /// Fires after every committed write; library screens fetch again on each one, as
  /// GRDB's `ValueObservation` re-runs their queries natively.
  Stream<int> get changes => dbWriter.changes;

  /// How many writes have committed, for comparing whether a fetched snapshot is current.
  int get revision => dbWriter.revision;

  static AppDatabase open({String? path, required AppPreferences preferences}) {
    final database = AppDatabase(SqlDatabase.open(path ?? AppStorage.localDbPath), preferences: preferences);
    database._repairOrphanWorks();
    return database;
  }

  static AppDatabase inMemory({AppPreferences? preferences}) {
    final database = AppDatabase(SqlDatabase.inMemory(), preferences: preferences ?? AppPreferences.memory());
    database._repairOrphanWorks();
    return database;
  }

  /// The source naming comics in taste events: the configured site address.
  String get comicSource => MangaUrls.sourceIn(preferences.defaults);
  TasteItem comicItem(int galleryId, [String? tags]) => TasteItem.comic(galleryId, tags: tags, source: comicSource);

  SqlMigrator get _migrator {
    final migrator = SqlMigrator();

    migrator.registerMigration('v1_create_schema', (db) {
      db.execute('''
        CREATE TABLE IF NOT EXISTS "folders" ("id" INTEGER PRIMARY KEY AUTOINCREMENT, "name" TEXT NOT NULL UNIQUE, "description" TEXT, "color" INTEGER NOT NULL DEFAULT 4288585374, "sort_order" INTEGER NOT NULL DEFAULT 0, "created_at" TEXT NOT NULL, "source_group_id" INTEGER);
        CREATE TABLE IF NOT EXISTS "works" ("id" INTEGER PRIMARY KEY AUTOINCREMENT, "gallery_id" INTEGER NOT NULL UNIQUE, "title" TEXT, "artists" TEXT, "language" TEXT, "type" TEXT, "series" TEXT, "groups" TEXT, "tags" TEXT, "note" TEXT, "bookmarked_at" TEXT NOT NULL, "published_at" TEXT, "last_opened_at" TEXT, "updated_at" TEXT, "metadata_source" TEXT, "catalog_matched" BOOLEAN NOT NULL DEFAULT 0, "thumb_status" TEXT NOT NULL DEFAULT 'missing', "thumb_path" TEXT, "thumb_failed_at" TEXT, "thumb_page" INTEGER DEFAULT 1);
        CREATE INDEX "idx_works_bookmarked" ON "works"("bookmarked_at");
        CREATE INDEX "idx_works_gallery_id" ON "works"("gallery_id");
        CREATE TABLE IF NOT EXISTS "folder_works" ("folder_id" INTEGER NOT NULL REFERENCES "folders"("id") ON DELETE CASCADE, "work_id" INTEGER NOT NULL REFERENCES "works"("id") ON DELETE CASCADE, "added_at" TEXT NOT NULL, PRIMARY KEY ("folder_id", "work_id"));
        CREATE TABLE IF NOT EXISTS "catalog_works" ("id" INTEGER PRIMARY KEY, "title" TEXT, "type" TEXT, "language" TEXT, "artists" TEXT, "groups" TEXT, "series" TEXT, "characters" TEXT, "tags" TEXT, "published" TEXT);
        CREATE INDEX "idx_catalog_title" ON "catalog_works"("title");
        CREATE TABLE IF NOT EXISTS "artists" ("id" INTEGER PRIMARY KEY AUTOINCREMENT, "name" TEXT NOT NULL, "kind" INTEGER NOT NULL DEFAULT 0, "note" TEXT, "folder_id" INTEGER REFERENCES "folders"("id") ON DELETE SET NULL, "bookmarked_at" TEXT NOT NULL, UNIQUE ("name", "kind"));
        CREATE TABLE IF NOT EXISTS "inbox" ("id" INTEGER PRIMARY KEY AUTOINCREMENT, "gallery_id" INTEGER NOT NULL, "raw_text" TEXT, "received_at" TEXT NOT NULL, "processed_at" TEXT);
        CREATE INDEX "idx_folder_works_work_id" ON "folder_works"("work_id");
        ''');
    });

    migrator.registerMigration('v2_thumb_page', (db) {
      if (!db.columns('works').contains('thumb_page')) db.execute('ALTER TABLE "works" ADD COLUMN "thumb_page" INTEGER DEFAULT 1');
    });

    migrator.registerMigration('v3_searches_and_sync_identity', (db) {
      db.execute('CREATE TABLE search_history (query TEXT PRIMARY KEY, used_at DOUBLE NOT NULL); CREATE TABLE saved_searches (query TEXT PRIMARY KEY);');
      db.execute('ALTER TABLE folders ADD COLUMN sync_id TEXT');
      for (final row in db.rows('SELECT id, name FROM folders')) {
        db.execute('UPDATE folders SET sync_id = ? WHERE id = ?', [row['name'] == '미분류' ? 'unsorted' : uuidString(), row['id']]);
      }
      db.execute('CREATE UNIQUE INDEX folder_sync_id ON folders(sync_id)');
    });
    migrator.registerMigration('v4_folder_order', (db) => db.execute('CREATE TABLE library_order (key TEXT PRIMARY KEY, value BLOB NOT NULL)'));
    migrator.registerMigration('v5_taste', TasteStore.migrate);
    migrator.registerMigration('v6_visual_fingerprints', VisualFingerprintStore.migrate);
    migrator.registerMigration('v7_visual_cleanup', VisualFingerprintStore.installDeletionTrigger);
    migrator.registerMigration('v8_default_folder_lifecycle', (db) {
      // Bootstrap once. Reopening an empty library must not recreate a deleted folder.
      if (db.value<int>('SELECT COUNT(*) FROM folders') == 0) unfiledFolder(db);
    });
    migrator.registerMigration(
      'v9_index_folder_works_work_id',
      (db) => db.execute('CREATE INDEX IF NOT EXISTS "idx_folder_works_work_id" ON "folder_works"("work_id")'),
    );
    migrator.registerMigration('v10_generic_import_metadata', (db) {
      final columns = db.columns('folders');
      if (columns.contains(MangaImportMetadata.groupIDKey)) return;
      final legacy = MangaImportMetadata.legacyGroupIDKey(columns);
      if (legacy != null) {
        db.execute('ALTER TABLE "folders" RENAME COLUMN "$legacy" TO "${MangaImportMetadata.groupIDKey}"');
      } else {
        db.execute('ALTER TABLE "folders" ADD COLUMN "${MangaImportMetadata.groupIDKey}" INTEGER');
      }
    });
    migrator.registerMigration('v11_folder_rule_rows', AppDatabaseFolderRules.adoptLegacyFolderRules);
    return migrator;
  }

  // MARK: - Folders & Color Generation

  static const curatedFolderColors = [
    0xFF2563EB, // Royal Blue
    0xFF059669, // Emerald Green
    0xFFEA580C, // Bright Orange
    0xFFE11D48, // Rose Red
    0xFF7C3AED, // Deep Purple
    0xFF0891B2, // Ocean Cyan
    0xFFD97706, // Amber Gold
    0xFFDB2777, // Vibrant Pink
    0xFF4F46E5, // Indigo
    0xFF0D9488, // Teal
    0xFF65A30D, // Lime Green
    0xFFC026D3, // Fuchsia
    0xFFDC2626, // Crimson
    0xFF9333EA, // Purple
    0xFF0284C7, // Sky Blue
    0xFFB45309, // Warm Brown
    0xFF16A34A, // Forest Green
    0xFFF97316, // Tangerine
    0xFF6366F1, // Periwinkle
    0xFF14B8A6, // Turquoise
    0xFF84CC16, // Lime
    0xFFEC4899, // Pink
    0xFFA855F7, // Purple
    0xFF3B82F6, // Blue
    0xFF10B981, // Mint
    0xFFF59E0B, // Yellow Orange
    0xFFEF4444, // Light Red
    0xFF64748B, // Slate
  ];

  static List<int> get presetColors => curatedFolderColors;

  static int colorFromHSV({required double h, required double s, required double v}) {
    final c = v * s;
    final modH = ((h % 1.0) + 1.0) % 1.0 * 6.0;
    final x = c * (1.0 - ((modH % 2.0) - 1.0).abs());
    final m = v - c;
    final (r1, g1, b1) = switch (modH.toInt() % 6) {
      0 => (c, x, 0.0),
      1 => (x, c, 0.0),
      2 => (0.0, c, x),
      3 => (0.0, x, c),
      4 => (x, 0.0, c),
      _ => (c, 0.0, x),
    };
    int channel(double value) => _roundHalfAway((value + m) * 255.0);
    return (0xFF << 24) | (channel(r1) << 16) | (channel(g1) << 8) | channel(b1);
  }

  /// Swift's `round` rounds halves away from zero, like Dart's `round`.
  static int _roundHalfAway(double value) => value.round();

  int nextUniqueFolderColorIn(SqlDatabase db, {Set<int> excluding = const {}}) =>
      nextFolderColor(existingColors: db.column<int>('SELECT color FROM folders'), excluding: excluding);

  /// Shared by both libraries: unused palette colors first, then golden-angle hues.
  static int nextFolderColor({required List<int> existingColors, Set<int> excluding = const {}}) {
    final used = {...existingColors, ...excluding};
    for (final color in curatedFolderColors) {
      if (!used.contains(color)) return color;
    }
    const goldenRatio = 0.618033988749895;
    final count = existingColors.length + excluding.length;
    final hue = (count * goldenRatio) % 1.0;
    return colorFromHSV(h: hue, s: 0.75, v: 0.88);
  }

  int nextUniqueFolderColor({Set<int> excluding = const {}}) {
    try {
      return dbWriter.read((db) => nextUniqueFolderColorIn(db, excluding: excluding));
    } on Object {
      return curatedFolderColors.first;
    }
  }

  static Folder unfiledFolder(SqlDatabase db) {
    final existing = db.row("SELECT * FROM folders WHERE sync_id = 'unsorted' OR name = '미분류' LIMIT 1");
    if (existing != null) return Folder.fromRow(existing);
    db.execute("INSERT INTO folders (name, description, color, sort_order, created_at, sync_id) VALUES ('미분류', '기본 폴더', 4280391411, 1, ?, 'unsorted')", [
      iso8601(),
    ]);
    return Folder.fromRow(db.row('SELECT * FROM folders WHERE id = ?', [db.lastInsertedRowID])!);
  }

  void _repairOrphanWorks() {
    final orphaned = dbWriter.read((db) => db.exists('SELECT EXISTS(SELECT 1 FROM works WHERE id NOT IN (SELECT work_id FROM folder_works))'));
    if (orphaned) ensureDefaultFolder();
  }

  Folder ensureDefaultFolder() => dbWriter.write((db) {
    final existing = db.row("SELECT * FROM folders WHERE name = '미분류' LIMIT 1") ?? db.row('SELECT * FROM folders ORDER BY sort_order ASC, id ASC LIMIT 1');
    final Folder folder;
    if (existing != null) {
      folder = Folder.fromRow(existing);
    } else {
      final now = iso8601();
      folder = Folder(name: '미분류', description: '기본 폴더', color: 4280391411, sortOrder: 1, createdAt: now);
      _insertFolder(folder, db);
    }

    // Link any orphan works to the default folder
    final defaultId = folder.id;
    if (defaultId != null) {
      db.execute(
        '''
        INSERT OR IGNORE INTO folder_works (folder_id, work_id, added_at)
        SELECT ?, id, bookmarked_at FROM works
        WHERE id NOT IN (SELECT work_id FROM folder_works)
        ''',
        [defaultId],
      );

      // Prune works from defaultFolder if they belong to other folders
      db.execute(
        '''
        DELETE FROM folder_works
        WHERE folder_id = ?
          AND work_id IN (SELECT work_id FROM folder_works WHERE folder_id != ?)
        ''',
        [defaultId, defaultId],
      );
    }
    return folder;
  });

  /// `Folder.insert(db)`: every persisted column, then the new row ID.
  static void _insertFolder(Folder folder, SqlDatabase db) {
    db.execute('INSERT INTO folders (id, name, description, color, sort_order, created_at, source_group_id) VALUES (?, ?, ?, ?, ?, ?, ?)', [
      folder.id,
      folder.name,
      folder.description,
      folder.color,
      folder.sortOrder,
      folder.createdAt,
      folder.sourceGroupId,
    ]);
    folder.id = db.lastInsertedRowID;
  }

  /// `Folder.save(db)`: update the row when it exists, otherwise insert it.
  static void saveFolder(Folder folder, SqlDatabase db) {
    if (folder.id != null && db.exists('SELECT EXISTS(SELECT 1 FROM folders WHERE id = ?)', [folder.id])) {
      db.execute('UPDATE folders SET name = ?, description = ?, color = ?, sort_order = ?, created_at = ?, source_group_id = ? WHERE id = ?', [
        folder.name,
        folder.description,
        folder.color,
        folder.sortOrder,
        folder.createdAt,
        folder.sourceGroupId,
        folder.id,
      ]);
    } else {
      _insertFolder(folder, db);
    }
  }

  /// The share extension's folder list has no Android counterpart yet.
  void syncFoldersToAppGroup() {}

  List<Folder> listFolders() => dbWriter.read(fetchFolders);

  /// Reused by observations so the snapshot is fetched in one read.
  static List<Folder> fetchFolders(SqlDatabase db) {
    const sql = '''
      SELECT f.*, COUNT(fw.work_id) AS work_count
      FROM folders f
      LEFT JOIN folder_works fw ON fw.folder_id = f.id
      GROUP BY f.id
      ORDER BY f.sort_order ASC, f.id ASC
      ''';
    final smart = AppDatabaseFolderRules.fetchFolderRules(db).where((rule) => rule.isActive).map((rule) => rule.folder).toSet();
    return [
      for (final row in db.rows(sql))
        Folder.fromRow(row, workCount: row['work_count'] as int)..isSmart = row['sync_id'] is String && smart.contains(row['sync_id']),
    ];
  }

  Map<int, List<Work>> folderPreviews({int limitPerFolder = 4}) => dbWriter.read((db) => fetchFolderPreviews(db, limitPerFolder: limitPerFolder));

  static Map<int, List<Work>> fetchFolderPreviews(SqlDatabase db, {int limitPerFolder = 4}) {
    const sql = '''
      WITH ranked AS (
          SELECT fw.folder_id, w.*,
                 ROW_NUMBER() OVER (
                     PARTITION BY fw.folder_id
                     ORDER BY COALESCE(NULLIF(w.bookmarked_at, ''), fw.added_at) DESC, w.id DESC
                 ) AS rn
          FROM folder_works fw
          INNER JOIN works w ON w.id = fw.work_id
      )
      SELECT * FROM ranked WHERE rn <= ?
      ''';
    final result = <int, List<Work>>{};
    for (final row in db.rows(sql, [limitPerFolder])) {
      result.putIfAbsent(row['folder_id'] as int, () => []).add(Work.fromRow(row));
    }
    return result;
  }

  Folder createFolder({required String name, String? description, int? color, int? sourceGroupId}) {
    final trimmedName = name.trim();
    final folder = dbWriter.write((db) {
      final resolvedColor = color ?? nextUniqueFolderColorIn(db);

      // 1. Check by sourceGroupId if provided
      if (sourceGroupId != null) {
        final row = db.row('SELECT * FROM folders WHERE source_group_id = ?', [sourceGroupId]);
        if (row != null) {
          final existing = Folder.fromRow(row);
          if (existing.name != trimmedName && trimmedName.isNotEmpty) {
            db.execute('UPDATE folders SET name = ? WHERE id = ?', [trimmedName, existing.id]);
            existing.name = trimmedName;
          }
          return existing;
        }
      }

      // 2. Check by name
      final named = db.row('SELECT * FROM folders WHERE name = ?', [trimmedName]);
      if (named != null) {
        final existing = Folder.fromRow(named);
        if (sourceGroupId != null && existing.sourceGroupId == null) {
          db.execute('UPDATE folders SET source_group_id = ? WHERE id = ?', [sourceGroupId, existing.id]);
          existing.sourceGroupId = sourceGroupId;
        }
        return existing;
      }

      final maxOrder = db.value<int>('SELECT MAX(sort_order) FROM folders') ?? 0;
      final newFolder = Folder(
        name: trimmedName,
        description: description,
        color: resolvedColor,
        sortOrder: maxOrder + 1,
        createdAt: iso8601(),
        sourceGroupId: sourceGroupId,
      );
      _insertFolder(newFolder, db);
      return newFolder;
    });
    syncFoldersToAppGroup();
    return folder;
  }

  void deleteFolder(int id) {
    dbWriter.write((db) {
      final row = db.row('SELECT * FROM folders WHERE id = ?', [id]);
      if (row == null) return;
      final folder = Folder.fromRow(row);
      final hasWorks = db.exists('SELECT EXISTS(SELECT 1 FROM folder_works WHERE folder_id = ?)', [id]);
      if (folder.name == '미분류' && hasWorks) throw const FolderDeletionError();
      final identity = db.value<String>('SELECT sync_id FROM folders WHERE id = ?', [id]);
      if (identity != null) db.execute('DELETE FROM library_order WHERE key = ?', [FolderRule.keyPrefix + identity]);
      if (!hasWorks) {
        db.execute('DELETE FROM folders WHERE id = ?', [id]);
        return;
      }
      final fallback =
          db.row("SELECT * FROM folders WHERE name = '미분류' AND id != ? LIMIT 1", [id]) ??
          db.row('SELECT * FROM folders WHERE id != ? ORDER BY sort_order ASC, id ASC LIMIT 1', [id]);
      final defaultFolder = fallback != null ? Folder.fromRow(fallback) : unfiledFolder(db);
      // Move works to default folder
      db.execute(
        '''
        INSERT OR IGNORE INTO folder_works (folder_id, work_id, added_at)
        SELECT ?, work_id, added_at FROM folder_works WHERE folder_id = ?
        ''',
        [defaultFolder.id, id],
      );
      db.execute('DELETE FROM folder_works WHERE folder_id = ?', [id]);
      db.execute('DELETE FROM folders WHERE id = ?', [id]);
    });
    syncFoldersToAppGroup();
  }

  void renameFolder(int id, String name) {
    dbWriter.write((db) => db.execute('UPDATE folders SET name = ? WHERE id = ?', [name.trim(), id]));
    syncFoldersToAppGroup();
  }

  void setFolderColor(int id, int color) {
    dbWriter.write((db) => db.execute('UPDATE folders SET color = ? WHERE id = ?', [color, id]));
    syncFoldersToAppGroup();
  }

  // MARK: - Works

  List<Work> listWorks({int? folderId, String? query, String? artist}) =>
      dbWriter.read((db) => fetchWorks(db, folderId: folderId, query: query, artist: artist));

  static List<Work> fetchWorks(SqlDatabase db, {int? folderId, String? query, String? artist}) {
    final conditions = <String>[];
    final arguments = <Object?>[];

    if (folderId != null) {
      conditions.add('w.id IN (SELECT work_id FROM folder_works WHERE folder_id = ?)');
      arguments.add(folderId);
    }
    if (artist != null && artist.isNotEmpty) {
      conditions.add('(w.artists LIKE ? OR w.groups LIKE ?)');
      arguments.addAll(['%$artist%', '%$artist%']);
    }
    if (query != null) {
      final (sql, values) = WorkQuery(query).conditions;
      if (sql.isNotEmpty) {
        conditions.add(sql);
        arguments.addAll(values);
      }
    }

    final whereClause = conditions.isEmpty ? '' : 'WHERE ${conditions.join(' AND ')}';
    final works = db.rows('SELECT w.* FROM works w $whereClause ORDER BY w.bookmarked_at DESC, w.id DESC', arguments).map(Work.fromRow).toList();

    // Join the same filtered works instead of binding one parameter per work.
    // Large imported libraries can exceed SQLite's parameter limit.
    if (works.isNotEmpty) {
      final folderSql =
          '''
        SELECT fw.work_id, f.* FROM folders f
        INNER JOIN folder_works fw ON fw.folder_id = f.id
        INNER JOIN works w ON w.id = fw.work_id
        $whereClause
        ORDER BY f.sort_order ASC, f.id ASC
        ''';
      final foldersByWorkId = <int, List<Folder>>{};
      for (final row in db.rows(folderSql, arguments)) {
        foldersByWorkId.putIfAbsent(row['work_id'] as int, () => []).add(Folder.fromRow(row));
      }
      for (final work in works) {
        if (work.id != null) work.folders = foldersByWorkId[work.id] ?? [];
      }
    }
    return works;
  }

  static Work? _workRow(SqlDatabase db, int galleryId) {
    final row = db.row('SELECT * FROM works WHERE gallery_id = ?', [galleryId]);
    return row == null ? null : Work.fromRow(row);
  }

  Work? getWork(int galleryId) => dbWriter.read((db) {
    final work = _workRow(db, galleryId);
    if (work?.id != null) {
      work!.folders = db
          .rows('SELECT f.* FROM folders f INNER JOIN folder_works fw ON fw.folder_id = f.id WHERE fw.work_id = ? ORDER BY f.sort_order ASC', [work.id])
          .map(Folder.fromRow)
          .toList();
    }
    return work;
  });

  /// `Work.insert(db)`.
  static void insertWork(Work work, SqlDatabase db) {
    db.execute('INSERT INTO works (id, ${Work.columns.join(', ')}) VALUES (?${', ?' * Work.columns.length})', [work.id, ...work.columnValues]);
    work.id = db.lastInsertedRowID;
  }

  /// `Work.update(db)`.
  static void updateWork(Work work, SqlDatabase db) =>
      db.execute('UPDATE works SET ${Work.columns.map((column) => '$column = ?').join(', ')} WHERE id = ?', [...work.columnValues, work.id]);

  /// `Work.save(db)`.
  static void saveWork(Work work, SqlDatabase db) {
    if (work.id != null && db.exists('SELECT EXISTS(SELECT 1 FROM works WHERE id = ?)', [work.id])) {
      updateWork(work, db);
    } else {
      insertWork(work, db);
    }
  }

  Work upsertWork({
    required int galleryId,
    int? folderId,
    String? title,
    String? artists,
    String? language,
    String? type,
    String? series,
    String? groups,
    String? tags,
    String? publishedAt,
    String? bookmarkedAt,
    String? metadataSource,
    bool catalogMatched = false,
    bool overwriteMetadata = false,
    DiscoveryContext? discoveryContext,
  }) => dbWriter.write((db) {
    final now = iso8601();
    var work = _workRow(db, galleryId);
    final wasNew = work == null;
    final lackedTags = (work?.tags ?? '').isEmpty;

    if (work != null) {
      final existing = work;
      if (overwriteMetadata || existing.metadataSource != 'manual') {
        if (title != null && title.isNotEmpty) existing.title = title;
        if (artists != null && artists.isNotEmpty) existing.artists = artists;
        if (language != null && language.isNotEmpty) existing.language = language;
        if (type != null && type.isNotEmpty) existing.type = type;
        if (series != null && series.isNotEmpty) existing.series = series;
        if (groups != null && groups.isNotEmpty) existing.groups = groups;
        if (tags != null && tags.isNotEmpty) existing.tags = tags;
        if (publishedAt != null && publishedAt.isNotEmpty) existing.publishedAt = publishedAt;
        if (metadataSource != null) existing.metadataSource = metadataSource;
        existing.catalogMatched = catalogMatched || existing.catalogMatched;
      }
      existing.updatedAt = now;
      updateWork(existing, db);
    } else {
      work = Work(
        galleryId: galleryId,
        title: title,
        artists: artists,
        language: language,
        type: type,
        series: series,
        groups: groups,
        tags: tags,
        bookmarkedAt: bookmarkedAt ?? now,
        publishedAt: publishedAt,
        updatedAt: now,
        metadataSource: metadataSource,
        catalogMatched: catalogMatched,
      );
      insertWork(work, db);
    }

    // A deleted last folder is recreated only when a new save actually needs one.
    var effectiveFolderId = folderId;
    if (effectiveFolderId == null && db.value<int>('SELECT COUNT(*) FROM folders') == 0) effectiveFolderId = unfiledFolder(db).id;
    if (effectiveFolderId != null) {
      final workId = work.id ?? db.value<int>('SELECT id FROM works WHERE gallery_id = ?', [galleryId]);
      if (workId != null) {
        db.execute('INSERT OR IGNORE INTO folder_works (folder_id, work_id, added_at) VALUES (?, ?, ?)', [effectiveFolderId, workId, now]);
        // If assigned to a non-default folder, remove from default folder (미분류)
        final defaultId = db.value<int>("SELECT id FROM folders WHERE name = '미분류' ORDER BY sort_order ASC, id ASC LIMIT 1");
        if (defaultId != null && defaultId != effectiveFolderId) {
          db.execute('DELETE FROM folder_works WHERE folder_id = ? AND work_id = ?', [defaultId, workId]);
        }
      }
    }

    if (lackedTags && (wasNew || (work.tags ?? '').isNotEmpty) && work.id != null) applyFolderRules(work.id!, now, db);
    final item = comicItem(galleryId, work.tags);
    if (wasNew && discoveryContext != null) {
      TasteStore.record(TasteEventKind.save, item, db, context: discoveryContext);
    } else if (wasNew) {
      TasteStore.record(TasteEventKind.imported, item, db);
    } else {
      TasteStore.record(TasteEventKind.metadata, item, db);
    }
    return work;
  });

  void addWorkToFolder(int workId, int folderId) {
    final now = iso8601();
    dbWriter.write((db) => db.execute('INSERT OR IGNORE INTO folder_works (folder_id, work_id, added_at) VALUES (?, ?, ?)', [folderId, workId, now]));
  }

  void setManualTitle(int galleryId, String title) {
    final now = iso8601();
    dbWriter.write((db) => db.execute("UPDATE works SET title = ?, metadata_source = 'manual', updated_at = ? WHERE gallery_id = ?", [title, now, galleryId]));
  }

  void setNote(int galleryId, String note) {
    final now = iso8601();
    dbWriter.write((db) => db.execute('UPDATE works SET note = ?, updated_at = ? WHERE gallery_id = ?', [note, now, galleryId]));
  }

  void markOpened(int galleryId) {
    final now = iso8601();
    dbWriter.write((db) => db.execute('UPDATE works SET last_opened_at = ? WHERE gallery_id = ?', [now, galleryId]));
  }

  void moveWorkToFolder(int galleryId, int targetFolderId, {int? currentFolderId}) {
    final now = iso8601();
    dbWriter.write((db) {
      final workId = _workRow(db, galleryId)?.id;
      if (workId == null) return;
      if (currentFolderId != null) {
        db.execute('DELETE FROM folder_works WHERE folder_id = ? AND work_id = ?', [currentFolderId, workId]);
      } else {
        db.execute('DELETE FROM folder_works WHERE work_id = ?', [workId]);
      }
      db.execute('INSERT OR IGNORE INTO folder_works (folder_id, work_id, added_at) VALUES (?, ?, ?)', [targetFolderId, workId, now]);
    });
  }

  void deleteWork(int galleryId) => dbWriter.write((db) {
    TasteStore.record(TasteEventKind.remove, comicItem(galleryId), db);
    final workId = _workRow(db, galleryId)?.id;
    if (workId != null) {
      db.execute('DELETE FROM folder_works WHERE work_id = ?', [workId]);
      db.execute('DELETE FROM works WHERE id = ?', [workId]);
    }
  });

  /// Called after a cover changes, for caches and visual fingerprints added by later screens.
  void Function(int galleryId, String path)? onThumbnailReady;

  void setThumb(int galleryId, String status, {String? path, int? page}) {
    final now = iso8601();
    // Invalidate before observers receive the updated thumbnail record.
    if (path != null) LocalThumbnailCache.shared.invalidate(path);
    dbWriter.write((db) {
      if (status == 'failed' || status == 'gone') {
        db.execute('UPDATE works SET thumb_status = ?, thumb_failed_at = ? WHERE gallery_id = ?', [status, now, galleryId]);
      } else if (status == 'ready') {
        if (page != null) {
          db.execute('UPDATE works SET thumb_status = ?, thumb_path = ?, thumb_page = ?, thumb_failed_at = NULL WHERE gallery_id = ?', [
            status,
            path,
            page,
            galleryId,
          ]);
        } else {
          db.execute('UPDATE works SET thumb_status = ?, thumb_path = ?, thumb_failed_at = NULL WHERE gallery_id = ?', [status, path, galleryId]);
        }
      } else {
        db.execute('UPDATE works SET thumb_status = ?, thumb_path = NULL WHERE gallery_id = ?', [status, galleryId]);
      }
    });
    if (status == 'ready' && path != null) onThumbnailReady?.call(galleryId, path);
  }

  void setThumbPage(int galleryId, int page) => dbWriter.write((db) => db.execute('UPDATE works SET thumb_page = ? WHERE gallery_id = ?', [page, galleryId]));

  /// Ready is a local-file promise, not a property that survives moving an
  /// app container. Repair old absolute paths before choosing backfill work.
  void repairThumbnailReferences(Directory directory) {
    final records = dbWriter.read((db) => db.rows("SELECT gallery_id, thumb_path FROM works WHERE thumb_status = 'ready'"));
    final changes = <({int id, String? old, String? recovered})>[];
    for (final row in records) {
      final id = row['gallery_id'] as int, old = row['thumb_path'] as String?;
      if (old != null && AppStorage.isReadableThumbnail(File(old))) continue;
      final candidates = [File('${directory.path}/native_$id.jpg')];
      if (old != null && old.isNotEmpty) candidates.insert(0, File('${directory.path}/${old.split('/').last}'));
      changes.add((id: id, old: old, recovered: candidates.where(AppStorage.isReadableThumbnail).firstOrNull?.path));
    }
    if (changes.isEmpty) return;
    dbWriter.write((db) {
      for (final change in changes) {
        db.execute(
          "UPDATE works SET thumb_status = ?, thumb_path = ?, thumb_failed_at = NULL WHERE gallery_id = ? AND thumb_status = 'ready' AND COALESCE(thumb_path, '') = ?",
          [change.recovered == null ? 'missing' : 'ready', change.recovered, change.id, change.old ?? ''],
        );
      }
    });
    for (final change in changes) {
      if (change.old case final old?) LocalThumbnailCache.shared.invalidate(old);
      if (change.recovered case final recovered?) LocalThumbnailCache.shared.invalidate(recovered);
    }
  }

  static const _needsFill = '''
    (thumb_status != 'gone' AND (thumb_status IN ('missing', 'failed')
     OR (thumb_status = 'ready' AND COALESCE(thumb_path, '') = '')
     OR TRIM(COALESCE(title, '')) = '' OR TRIM(COALESCE(tags, '')) = ''))
    ''';

  List<Work> worksNeedingFill({int limit = 8, Set<int> exclude = const {}}) => dbWriter.read((db) {
    final placeholders = exclude.isEmpty ? '' : 'AND gallery_id NOT IN (${exclude.join(',')})';
    return db.rows('SELECT * FROM works WHERE $_needsFill\n$placeholders\nORDER BY bookmarked_at DESC, id DESC\nLIMIT ?', [limit]).map(Work.fromRow).toList();
  });

  int countNeedingFill({Set<int> exclude = const {}}) {
    final exclusions = exclude.isEmpty ? '' : ' AND gallery_id NOT IN (${exclude.join(',')})';
    return dbWriter.read((db) => db.value<int>('SELECT COUNT(*) FROM works WHERE $_needsFill$exclusions') ?? 0);
  }

  List<int> savedGalleryIDs() => dbWriter.read((db) => db.column<int>('SELECT gallery_id FROM works ORDER BY bookmarked_at DESC, id DESC'));

  int worksCount() => dbWriter.read((db) => db.value<int>('SELECT COUNT(*) FROM works')!);

  int missingTitleCount() => dbWriter.read((db) => db.value<int>("SELECT COUNT(*) FROM works WHERE title IS NULL OR TRIM(title) = ''") ?? 0);

  // MARK: - Catalog Works

  CatalogWork? getCatalog(int galleryId) => dbWriter.read((db) {
    final row = db.row('SELECT * FROM catalog_works WHERE id = ?', [galleryId]);
    return row == null ? null : CatalogWork.fromRow(row);
  });

  int catalogCount() => dbWriter.read((db) => db.value<int>('SELECT COUNT(*) FROM catalog_works')!);

  List<int> listAllGalleryIds() => dbWriter.read((db) => db.column<int>('SELECT gallery_id FROM works ORDER BY id DESC'));

  List<int> listGalleryIdsNeedingMetadata() => dbWriter.read(
    (db) =>
        db.column<int>("SELECT gallery_id FROM works WHERE title IS NULL OR title = '' OR tags IS NULL OR tags = '' OR catalog_matched = 0 ORDER BY id DESC"),
  );

  static const _insertCatalog =
      'INSERT OR REPLACE INTO catalog_works (id, title, type, language, artists, groups, series, characters, tags, published) VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?)';

  static List<Object?> _catalogValues(CatalogWork item) => [
    item.id,
    item.title,
    item.type,
    item.language,
    item.artists,
    item.groups,
    item.series,
    item.characters,
    item.tags,
    item.published,
  ];

  int applyCatalogBatchToWorks(List<CatalogWork> items) {
    if (items.isEmpty) return 0;
    final now = iso8601();
    return dbWriter.write((db) {
      const updateSql = '''
        UPDATE works
        SET title = CASE WHEN (title IS NULL OR title = '' OR metadata_source != 'manual') THEN ? ELSE title END,
            artists = CASE WHEN (artists IS NULL OR artists = '' OR metadata_source != 'manual') THEN ? ELSE artists END,
            language = CASE WHEN (language IS NULL OR language = '' OR metadata_source != 'manual') THEN ? ELSE language END,
            type = CASE WHEN (type IS NULL OR type = '' OR metadata_source != 'manual') THEN ? ELSE type END,
            series = CASE WHEN (series IS NULL OR series = '' OR metadata_source != 'manual') THEN ? ELSE series END,
            groups = CASE WHEN (groups IS NULL OR groups = '' OR metadata_source != 'manual') THEN ? ELSE groups END,
            tags = CASE WHEN (tags IS NULL OR tags = '' OR metadata_source != 'manual') THEN ? ELSE tags END,
            published_at = CASE WHEN published_at IS NULL THEN ? ELSE published_at END,
            catalog_matched = 1,
            metadata_source = CASE WHEN metadata_source = 'manual' THEN 'manual' ELSE 'catalog' END,
            updated_at = ?
        WHERE gallery_id = ?
        ''';
      var updatedCount = 0;
      for (final item in items) {
        final untagged = db.value<int>("SELECT id FROM works WHERE gallery_id = ? AND COALESCE(tags, '') = ''", [item.id]);
        db.execute(updateSql, [item.title, item.artists, item.language, item.type, item.series, item.groups, item.tags, item.published, now, item.id]);
        if (db.changesCount > 0) updatedCount += 1;
        if (untagged != null && (item.tags ?? '').isNotEmpty) applyFolderRules(untagged, now, db);
        db.execute(_insertCatalog, _catalogValues(item));
      }
      return updatedCount;
    });
  }

  void upsertCatalogBatch(List<CatalogWork> batch) => dbWriter.write((db) {
    for (final item in batch) {
      db.execute(_insertCatalog, _catalogValues(item));
    }
  });

  void applyCatalogToWorks() {
    final now = iso8601();
    dbWriter.write((db) {
      final untagged = db.column<int>('''
        SELECT w.id FROM works w JOIN catalog_works c ON c.id = w.gallery_id
        WHERE COALESCE(w.tags, '') = '' AND COALESCE(c.tags, '') != ''
          AND (w.title IS NULL OR w.metadata_source != 'manual')
        ''');
      db.execute('''
        UPDATE works
        SET title = (SELECT c.title FROM catalog_works c WHERE c.id = works.gallery_id),
            artists = (SELECT c.artists FROM catalog_works c WHERE c.id = works.gallery_id),
            language = (SELECT c.language FROM catalog_works c WHERE c.id = works.gallery_id),
            type = (SELECT c.type FROM catalog_works c WHERE c.id = works.gallery_id),
            series = (SELECT c.series FROM catalog_works c WHERE c.id = works.gallery_id),
            groups = (SELECT c.groups FROM catalog_works c WHERE c.id = works.gallery_id),
            tags = (SELECT c.tags FROM catalog_works c WHERE c.id = works.gallery_id),
            published_at = (SELECT c.published FROM catalog_works c WHERE c.id = works.gallery_id),
            catalog_matched = 1,
            metadata_source = CASE WHEN metadata_source = 'manual' THEN 'manual' ELSE 'catalog' END
        WHERE EXISTS (SELECT 1 FROM catalog_works c WHERE c.id = works.gallery_id)
          AND (title IS NULL OR metadata_source != 'manual')
        ''');
      for (final id in untagged) {
        applyFolderRules(id, now, db);
      }
    });
  }

  // MARK: - Artists

  List<ArtistMemo> listArtists() => dbWriter.read((db) => db.rows('SELECT * FROM artists ORDER BY name ASC').map(ArtistMemo.fromRow).toList());

  ArtistMemo addFavoriteArtist(String name, {int kind = 0}) {
    final trimmedName = name.trim();
    return dbWriter.write((db) {
      final existing = db.row('SELECT * FROM artists WHERE name = ? AND kind = ?', [trimmedName, kind]);
      if (existing != null) return ArtistMemo.fromRow(existing);
      final artist = ArtistMemo(name: trimmedName, kind: kind);
      db.execute('INSERT INTO artists (name, kind, note, folder_id, bookmarked_at) VALUES (?, ?, ?, ?, ?)', [
        artist.name,
        artist.kind,
        artist.note,
        artist.folderId,
        artist.bookmarkedAt,
      ]);
      artist.id = db.lastInsertedRowID;
      return artist;
    });
  }

  void removeFavoriteArtist(String name, {int? kind}) {
    final trimmedName = name.trim();
    dbWriter.write((db) {
      if (kind != null) {
        db.execute('DELETE FROM artists WHERE name = ? AND kind = ?', [trimmedName, kind]);
      } else {
        db.execute('DELETE FROM artists WHERE name = ?', [trimmedName]);
      }
    });
  }

  void saveCollectionTag(String raw, SavedCollectionKind kind) {
    final name = kind.normalized(raw);
    if (name.isEmpty || kind == SavedCollectionKind.history) return;
    if (kind == SavedCollectionKind.search) {
      if (!savedSearches().contains(name)) toggleSavedSearch(name);
    } else if (kind.mangaKind case final code?) {
      final exists = listArtists().any((artist) => artist.kind == code && SavedCollectionKind.identity(artist.name) == SavedCollectionKind.identity(name));
      if (!exists) addFavoriteArtist(name, kind: code);
    }
  }

  bool toggleCollectionTag(String raw, SavedCollectionKind kind) {
    final name = kind.normalized(raw);
    if (name.isEmpty) return false;
    if (kind == SavedCollectionKind.search || kind == SavedCollectionKind.history) {
      final saved = savedSearches().contains(name);
      toggleSavedSearch(name);
      return !saved;
    }
    final code = kind.mangaKind;
    if (code == null) return false;
    final matching = listArtists()
        .where((artist) => artist.kind == code && SavedCollectionKind.identity(artist.name) == SavedCollectionKind.identity(name))
        .toList();
    if (matching.isEmpty) {
      saveCollectionTag(name, kind);
      return true;
    }
    for (final value in matching) {
      removeFavoriteArtist(value.name, kind: code);
    }
    return false;
  }

  // MARK: - Search library (SearchLibrary.swift)

  List<String> searchHistory() => dbWriter.read(
    (db) => db.column<String>('SELECT query FROM search_history WHERE used_at >= ? ORDER BY used_at DESC LIMIT 500', [
      SearchRetention.cutoff(preferences.defaults),
    ]),
  );

  List<String> savedSearches() => dbWriter.read((db) => db.column<String>('SELECT query FROM saved_searches ORDER BY query'));

  void recordSearch(String query) {
    final value = query.trim();
    if (value.isEmpty) return;
    dbWriter.write((db) {
      db.execute('INSERT OR REPLACE INTO search_history VALUES (?, ?)', [value, unixSeconds()]);
      db.execute('DELETE FROM search_history WHERE used_at < ?', [SearchRetention.cutoff(preferences.defaults)]);
    });
  }

  void deleteSearch(String query) => dbWriter.write((db) => db.execute('DELETE FROM search_history WHERE query = ?', [query]));
  void clearSearchHistory() => dbWriter.write((db) => db.execute('DELETE FROM search_history'));

  void toggleSavedSearch(String query) => dbWriter.write((db) {
    db.execute('DELETE FROM saved_searches WHERE query = ?', [query]);
    if (db.changesCount == 0) db.execute('INSERT INTO saved_searches VALUES (?)', [query]);
  });

  void reorderFolders(List<int> ids) {
    dbWriter.write((db) {
      final existing = db.column<int>('SELECT id FROM folders ORDER BY sort_order, id');
      final seen = <int>{};
      final completeOrder = [...ids, ...existing].where((id) => existing.contains(id) && seen.add(id)).toList();
      for (final (position, id) in completeOrder.indexed) {
        db.execute("UPDATE folders SET sort_order = ?, sync_id = COALESCE(sync_id, CASE WHEN name = '미분류' THEN 'unsorted' ELSE ? END) WHERE id = ?", [
          position,
          uuidString(),
          id,
        ]);
      }
      final order = db.column<String?>('SELECT sync_id FROM folders ORDER BY sort_order, id');
      db.execute("INSERT OR REPLACE INTO library_order VALUES ('folders', ?)", [encodeSwiftJson(order)]);
    });
    syncFoldersToAppGroup();
  }

  void deleteSelectedWorks(Set<int> ids) => dbWriter.write((db) {
    for (final id in ids) {
      TasteStore.record(TasteEventKind.remove, comicItem(id), db);
      db.execute('DELETE FROM folder_works WHERE work_id IN (SELECT id FROM works WHERE gallery_id = ?)', [id]);
      db.execute('DELETE FROM works WHERE gallery_id = ?', [id]);
    }
  });

  void moveSelectedWorks(Set<int> ids, int toFolderID, {int? from}) => dbWriter.write((db) {
    for (final id in ids) {
      final work = db.value<int>('SELECT id FROM works WHERE gallery_id = ?', [id]);
      if (work == null) continue;
      if (from != null) {
        db.execute('DELETE FROM folder_works WHERE work_id = ? AND folder_id = ?', [work, from]);
      } else {
        db.execute('DELETE FROM folder_works WHERE work_id = ?', [work]);
      }
      db.execute('INSERT OR IGNORE INTO folder_works VALUES (?, ?, ?)', [toFolderID, work, iso8601()]);
    }
  });

  void pruneSearchHistory() {
    try {
      dbWriter.write((db) => db.execute('DELETE FROM search_history WHERE used_at < ?', [SearchRetention.cutoff(preferences.defaults)]));
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
  List<FolderRule> smartRules() => folderRules().map((entry) => entry.rule).toList();
  @override
  int matchingCount(FolderRule rule) => matchingWorkCount(rule);
  @override
  String createRuleFolder(String named) => createRuleFolderNamed(named);
  @override
  void saveRule(FolderRule rule) => saveFolderRule(rule);
  @override
  void deleteRule(String forFolder) => deleteFolderRule(forFolder);
  @override
  void fill(FolderRule rule) => fillRule(rule);
}

abstract final class SearchRetention {
  static int days(Preferences defaults) => defaults.integerOrNull('search.retentionDays') ?? 0;

  static double cutoff(Preferences defaults) {
    final days = SearchRetention.days(defaults);
    return days == 0 ? 0 : unixSeconds(DateTime.now().subtract(Duration(seconds: days * 86400)));
  }
}
