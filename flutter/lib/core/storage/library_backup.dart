import 'dart:io';
import 'dart:typed_data';

import '../../domain/models.dart';
import '../booru/booru_backup.dart';
import '../booru/booru_store.dart';
import '../challenge/challenge_models.dart';
import '../challenge/challenge_store.dart';
import '../content/reading_queue.dart';
import '../content/recent_works.dart';
import '../support/l10n.dart';
import '../support/sql_database.dart';
import '../support/swift_json.dart';
import '../taste/taste_models.dart';
import '../taste/taste_store.dart';
import 'app_database.dart';
import 'folder_rules.dart';

class LibraryBackupError implements Exception {
  const LibraryBackupError();
  String get errorDescription => L10n.text('This backup is invalid, too large, or uses an unsupported version.');
  @override
  String toString() => 'LibraryBackupError.invalid';
}

/// One portable document for both libraries. Media, caches and credentials stay local.
class LibraryBackup {
  LibraryBackup({this.format = 'tegnal-library', this.version = 1, String? exportedAt, required this.comics, required this.images, required this.challenges})
    : exportedAt = exportedAt ?? iso8601();

  String format;
  int version;
  String exportedAt;
  MangaBackup comics;
  BooruBackup images;
  ChallengeBackup challenges;
  static const maximumBytes = 128 * 1024 * 1024;

  static LibraryBackup capture(AppDatabase database, BooruStore images, {List<RecentWork> recentWorks = const [], List<RecentImage> recentImages = const []}) {
    final imageBackup = images.exportBackup();
    for (final favorite in imageBackup.favorites) {
      favorite.post = favorite.post.cloudMetadata;
    }
    final serverIDs = {for (final server in imageBackup.servers) server.id};
    final recents = [
      for (final recent in recentImages)
        if (serverIDs.contains(recent.post.serverID))
          BooruBackupRecent(post: recent.post.cloudMetadata, openedAt: recent.openedAt.millisecondsSinceEpoch / 1000),
    ];
    // Left out when empty, so a backup without them reads exactly as before.
    if (recents.isNotEmpty) imageBackup.recentImages = recents;
    final value = LibraryBackup(
      comics: MangaBackup.capture(database)..recentWorks = recentWorks.isEmpty ? null : [for (final work in recentWorks) MangaRecentRecord.fromWork(work)],
      images: imageBackup,
      challenges: ChallengeBackup(games: ChallengeStore(images).definitions()),
    );
    value.validate();
    return value;
  }

  void validate() {
    if (format != 'tegnal-library' || version != 1) throw const LibraryBackupError();
    comics.validate();
    images.validate();
    challenges.validate();
  }

  factory LibraryBackup.fromJson(JsonObject json) => LibraryBackup(
    format: json.string('format'),
    version: json.integer('version'),
    exportedAt: json.string('exportedAt'),
    comics: MangaBackup.fromJson(json.object('comics')),
    images: BooruBackup.fromJson(json.object('images')),
    challenges: ChallengeBackup.fromJson(json.object('challenges')),
  );

  JsonObject toJson() => {
    'format': format,
    'version': version,
    'exportedAt': exportedAt,
    'comics': comics.toJson(),
    'images': images.toJson(),
    'challenges': challenges.toJson(),
  };

  Uint8List encoded() {
    validate();
    final data = encodeJson(toJson(), pretty: true, escapingSlashes: false);
    if (data.length > maximumBytes) throw const LibraryBackupError();
    return data;
  }

  /// Writes `tegnal-backup.json` into a new folder under `temporary`, ready to share.
  static File export(
    AppDatabase database,
    BooruStore images, {
    required Directory temporary,
    List<RecentWork> recentWorks = const [],
    List<RecentImage> recentImages = const [],
  }) {
    final directory = Directory('${temporary.path}/${uuidString()}')..createSync(recursive: true);
    return File('${directory.path}/tegnal-backup.json')
      ..writeAsBytesSync(capture(database, images, recentWorks: recentWorks, recentImages: recentImages).encoded(), flush: true);
  }
}

/// A missing mode in an older backup never clears the other mode's local library.
class LibraryBackupImport {
  LibraryBackupImport({this.comics, this.images, this.challenges});
  final MangaBackup? comics;
  final BooruBackup? images;
  final ChallengeBackup? challenges;

  int get workCount => (comics?.works.length ?? 0) + (images?.favorites.length ?? 0);
  int get folderCount => (comics?.folders.length ?? 0) + (images?.folders.length ?? 0);

  static LibraryBackupImport read(File file) {
    if (file.lengthSync() > LibraryBackup.maximumBytes) throw const LibraryBackupError();
    return decode(file.readAsBytesSync());
  }

  static LibraryBackupImport decode(List<int> data) {
    if (data.length > LibraryBackup.maximumBytes) throw const LibraryBackupError();
    final JsonObject object;
    try {
      object = decodeJsonObject(data);
    } on SwiftJsonError {
      throw const LibraryBackupError();
    }
    final LibraryBackupImport value;
    if (object['format'] == 'tegnal-library') {
      final combined = LibraryBackup.fromJson(object);
      combined.validate();
      value = LibraryBackupImport(comics: combined.comics, images: combined.images, challenges: combined.challenges);
    } else if (object.containsKey('format')) {
      // Keep standalone image and challenge imports compatible with their existing formats.
      final images = _attempt(() => BooruBackup.decode(data));
      final challenges = images == null ? _attempt(() => ChallengeBackup.decode(data)) : null;
      if (images != null) {
        value = LibraryBackupImport(images: images);
      } else if (challenges != null) {
        value = LibraryBackupImport(challenges: challenges);
      } else {
        throw const LibraryBackupError();
      }
    } else {
      final folders = object['folders'];
      if (folders is List) {
        object['folders'] = [for (final folder in folders) folder is Map<String, Object?> ? MangaImportMetadata.normalized(folder) : folder];
      }
      value = LibraryBackupImport(comics: MangaBackup.fromJson(object));
    }
    value.validate();
    return value;
  }

  static T? _attempt<T>(T Function() decode) {
    try {
      return decode();
    } on Object {
      return null;
    }
  }

  void validate() {
    if (comics == null && images == null && challenges == null) throw const LibraryBackupError();
    comics?.validate();
    images?.validate();
    challenges?.validate();
  }

  /// Validate everything before touching either library. An error during either
  /// write body rolls back both transactions; records absent from the file stay local.
  void restore(AppDatabase database, BooruStore store) {
    validate();
    database.dbWriter.write((mangaDB) {
      store.database.write((imageDB) {
        comics?.restore(mangaDB, database);
        if (images != null) store.restoreBackupIn(images!, imageDB);
        for (final game in challenges?.games ?? <ChallengeDefinition>[]) {
          imageDB.execute('INSERT INTO challenges (id, payload) VALUES (?, ?) ON CONFLICT(id) DO UPDATE SET payload = excluded.payload', [
            game.id,
            encodeSwiftJson(game.toJson()),
          ]);
        }
      });
    });
    store.refresh();
  }
}

class MangaFolderRecord {
  MangaFolderRecord({this.id, required this.name, this.color, this.sortOrder, this.sourceGroupId, this.description});
  final int? id;
  final String name;
  final int? color;
  final int? sortOrder;
  final int? sourceGroupId;
  final String? description;

  factory MangaFolderRecord.fromJson(JsonObject json) => MangaFolderRecord(
    id: json.integerOrNull('id'),
    name: json.string('name'),
    color: json.integerOrNull('color'),
    sortOrder: json.integerOrNull('sort_order'),
    sourceGroupId: json.integerOrNull('source_group_id'),
    description: json.stringOrNull('description'),
  );
  JsonObject toJson() => <String, Object?>{'name': name}
    ..putIfPresent('id', id)
    ..putIfPresent('color', color)
    ..putIfPresent('sort_order', sortOrder)
    ..putIfPresent('source_group_id', sourceGroupId)
    ..putIfPresent('description', description);
}

class MangaWorkRecord {
  MangaWorkRecord({
    required this.galleryId,
    this.title,
    this.artists,
    this.note,
    this.bookmarkedAt,
    this.language,
    this.type,
    this.series,
    this.groups,
    this.tags,
    this.publishedAt,
    this.thumbPage,
    this.site,
    this.folders,
  });
  final int galleryId;
  final String? title;
  final String? artists;
  final String? note;
  final String? bookmarkedAt;
  final String? language;
  final String? type;
  final String? series;
  final String? groups;
  final String? tags;
  final String? publishedAt;
  final int? thumbPage;

  /// The comics site the work was saved from; older backups leave it out.
  final String? site;
  final List<String>? folders;

  factory MangaWorkRecord.fromJson(JsonObject json) => MangaWorkRecord(
    galleryId: json.integer('gallery_id'),
    title: json.stringOrNull('title'),
    artists: json.stringOrNull('artists'),
    note: json.stringOrNull('note'),
    bookmarkedAt: json.stringOrNull('bookmarked_at'),
    language: json.stringOrNull('language'),
    type: json.stringOrNull('type'),
    series: json.stringOrNull('series'),
    groups: json.stringOrNull('groups'),
    tags: json.stringOrNull('tags'),
    publishedAt: json.stringOrNull('published_at'),
    thumbPage: json.integerOrNull('thumb_page'),
    site: json.stringOrNull('site'),
    folders: json.stringsOrNull('folders'),
  );
  JsonObject toJson() => <String, Object?>{'gallery_id': galleryId}
    ..putIfPresent('title', title)
    ..putIfPresent('artists', artists)
    ..putIfPresent('note', note)
    ..putIfPresent('bookmarked_at', bookmarkedAt)
    ..putIfPresent('language', language)
    ..putIfPresent('type', type)
    ..putIfPresent('series', series)
    ..putIfPresent('groups', groups)
    ..putIfPresent('tags', tags)
    ..putIfPresent('published_at', publishedAt)
    ..putIfPresent('thumb_page', thumbPage)
    ..putIfPresent('site', site)
    ..putIfPresent('folders', folders);
}

class MangaArtistRecord {
  MangaArtistRecord({required this.name, this.kind, this.note});
  final String name;
  final int? kind;
  final String? note;

  factory MangaArtistRecord.fromJson(JsonObject json) =>
      MangaArtistRecord(name: json.string('name'), kind: json.integerOrNull('kind'), note: json.stringOrNull('note'));
  JsonObject toJson() => <String, Object?>{'name': name}
    ..putIfPresent('kind', kind)
    ..putIfPresent('note', note);
}

class MangaSearchRecord {
  MangaSearchRecord({required this.query, required this.usedAt});
  final String query;
  final double usedAt;

  factory MangaSearchRecord.fromJson(JsonObject json) => MangaSearchRecord(query: json.string('query'), usedAt: json.number('used_at'));
  JsonObject toJson() => {'query': query, 'used_at': usedAt};
}

class MangaRuleRecord {
  MangaRuleRecord({required this.folder, required this.query, this.excluded, this.includesOtherFolders, this.isEnabled, this.sources, this.keepsOriginal});
  final String folder;
  final bool? keepsOriginal;
  final String query;
  final String? excluded;
  final bool? includesOtherFolders;
  final bool? isEnabled;
  final List<String>? sources;

  factory MangaRuleRecord.fromJson(JsonObject json) => MangaRuleRecord(
    folder: json.string('folder'),
    query: json.string('query'),
    excluded: json.stringOrNull('excluded'),
    includesOtherFolders: json.booleanOrNull('includesOtherFolders'),
    isEnabled: json.booleanOrNull('isEnabled'),
    sources: json.stringsOrNull('sources'),
    keepsOriginal: json.booleanOrNull('keepsOriginal'),
  );
  JsonObject toJson() => <String, Object?>{'folder': folder, 'query': query}
    ..putIfPresent('excluded', excluded)
    ..putIfPresent('includesOtherFolders', includesOtherFolders)
    ..putIfPresent('isEnabled', isEnabled)
    ..putIfPresent('sources', sources)
    ..putIfPresent('keepsOriginal', keepsOriginal);
}

/// A recently opened work; `opened_at` is seconds since 1970, as both apps write it.
class MangaRecentRecord {
  MangaRecentRecord({
    required this.galleryId,
    required this.title,
    required this.artists,
    required this.details,
    this.site,
    this.language,
    this.type,
    this.tags,
    required this.openedAt,
  });

  factory MangaRecentRecord.fromWork(RecentWork work) => MangaRecentRecord(
    galleryId: work.id,
    title: work.item.title,
    artists: work.item.artists,
    details: work.item.details,
    site: work.item.site,
    language: work.language,
    type: work.type,
    tags: work.tags,
    openedAt: work.openedAt.millisecondsSinceEpoch / 1000,
  );

  factory MangaRecentRecord.fromJson(JsonObject json) => MangaRecentRecord(
    galleryId: json.integer('gallery_id'),
    title: json.string('title'),
    artists: json.string('artists'),
    details: json.string('details'),
    site: json.stringOrNull('site'),
    language: json.stringOrNull('language'),
    type: json.stringOrNull('type'),
    tags: json.stringsOrNull('tags'),
    openedAt: json.number('opened_at'),
  );

  final int galleryId;
  final String title;
  final String artists;
  final String details;
  final String? site;
  final String? language;
  final String? type;
  final List<String>? tags;
  final double openedAt;

  RecentWork get work => RecentWork(
    item: ReadingQueueItem(id: galleryId, title: title, artists: artists, details: details, site: site),
    openedAt: DateTime.fromMillisecondsSinceEpoch((openedAt * 1000).round()),
    language: language,
    type: type,
    tags: tags,
  );

  JsonObject toJson() => <String, Object?>{'gallery_id': galleryId, 'title': title, 'artists': artists, 'details': details, 'opened_at': openedAt}
    ..putIfPresent('site', site)
    ..putIfPresent('language', language)
    ..putIfPresent('type', type)
    ..putIfPresent('tags', tags);
}

/// The original comics JSON shape remains readable, with portable fields only.
class MangaBackup {
  MangaBackup({
    this.version = 2,
    this.exportedAt,
    required this.folders,
    required this.works,
    required this.artists,
    this.history,
    this.savedSearches,
    this.folderRules,
    this.recentWorks,
  });

  int version;
  String? exportedAt;
  List<MangaFolderRecord> folders;
  List<MangaWorkRecord> works;
  List<MangaArtistRecord> artists;
  List<MangaSearchRecord>? history;
  List<String>? savedSearches;
  List<MangaRuleRecord>? folderRules;

  /// Optional so backups from before recent works still read.
  List<MangaRecentRecord>? recentWorks;

  factory MangaBackup.fromJson(JsonObject json) => MangaBackup(
    version: json.integer('version'),
    exportedAt: json.stringOrNull('exported_at'),
    folders: json.list('folders', (value) => MangaFolderRecord.fromJson(jsonObject(value))),
    works: json.list('works', (value) => MangaWorkRecord.fromJson(jsonObject(value))),
    artists: json.list('artists', (value) => MangaArtistRecord.fromJson(jsonObject(value))),
    history: json.listOrNull('history', (value) => MangaSearchRecord.fromJson(jsonObject(value))),
    savedSearches: json.stringsOrNull('saved_searches'),
    folderRules: json.listOrNull('folder_rules', (value) => MangaRuleRecord.fromJson(jsonObject(value))),
    recentWorks: json.listOrNull('recent_works', (value) => MangaRecentRecord.fromJson(jsonObject(value))),
  );

  JsonObject toJson() =>
      <String, Object?>{
          'version': version,
          'folders': [for (final folder in folders) folder.toJson()],
          'works': [for (final work in works) work.toJson()],
          'artists': [for (final artist in artists) artist.toJson()],
        }
        ..putIfPresent('exported_at', exportedAt)
        ..putIfPresent('history', history == null ? null : [for (final search in history!) search.toJson()])
        ..putIfPresent('saved_searches', savedSearches)
        ..putIfPresent('folder_rules', folderRules == null ? null : [for (final rule in folderRules!) rule.toJson()])
        ..putIfPresent('recent_works', recentWorks == null ? null : [for (final recent in recentWorks!) recent.toJson()]);

  static MangaBackup capture(AppDatabase database) => database.dbWriter.read((db) {
    final folders = AppDatabase.fetchFolders(db);
    final works = AppDatabase.fetchWorks(db);
    final artists = db.rows('SELECT * FROM artists ORDER BY name ASC').map(ArtistMemo.fromRow).toList();
    final rules = <MangaRuleRecord>[];
    for (final rule in AppDatabaseFolderRules.fetchFolderRules(db)) {
      final id = AppDatabaseFolderRules.folderIDOfRule(rule, db);
      final folder = folders.where((folder) => folder.id == id).firstOrNull;
      if (id == null || folder == null) continue;
      final sources = rule.sources?.map((source) => db.value<String>('SELECT name FROM folders WHERE sync_id = ?', [source])).nonNulls.toList();
      rules.add(
        MangaRuleRecord(
          folder: folder.name,
          query: rule.query,
          excluded: rule.excluded,
          includesOtherFolders: rule.includesOtherFolders,
          isEnabled: rule.isEnabled,
          sources: sources,
          keepsOriginal: rule.keepsOriginal,
        ),
      );
    }
    return MangaBackup(
      exportedAt: iso8601(),
      folders: [
        for (final folder in folders)
          MangaFolderRecord(
            id: folder.id,
            name: folder.name,
            color: folder.color,
            sortOrder: folder.sortOrder,
            sourceGroupId: folder.sourceGroupId,
            description: folder.description,
          ),
      ],
      works: [
        for (final work in works)
          MangaWorkRecord(
            galleryId: work.galleryId,
            title: work.title,
            artists: work.artists,
            note: work.note,
            bookmarkedAt: work.bookmarkedAt,
            language: work.language,
            type: work.type,
            series: work.series,
            groups: work.groups,
            tags: work.tags,
            publishedAt: work.publishedAt,
            thumbPage: work.thumbPage,
            site: work.site,
            folders: work.folders.map((folder) => folder.name).toList(),
          ),
      ],
      artists: [for (final artist in artists) MangaArtistRecord(name: artist.name, kind: artist.kind, note: artist.note)],
      history: [
        for (final row in db.rows('SELECT * FROM search_history ORDER BY used_at DESC'))
          MangaSearchRecord(query: row['query'] as String, usedAt: (row['used_at'] as num).toDouble()),
      ],
      savedSearches: db.column<String>('SELECT query FROM saved_searches ORDER BY query'),
      folderRules: rules,
    );
  });

  void validate() {
    final names = folders.map((folder) => folder.name).toSet();
    final mangaKinds = SavedCollectionKind.values.map((kind) => kind.mangaKind).nonNulls.toSet();
    final valid =
        (version == 1 || version == 2) &&
        names.length == folders.length &&
        folders.every((folder) {
          final color = folder.color ?? 0xFF2563EB;
          return folder.name.trim().isNotEmpty && color >= 0 && color <= 0xFFFFFFFF;
        }) &&
        works.map((work) => work.galleryId).toSet().length == works.length &&
        works.every((work) => work.galleryId > 0 && (work.thumbPage ?? 1) > 0 && names.containsAll(work.folders ?? const [])) &&
        artists.every((artist) => artist.name.trim().isNotEmpty && mangaKinds.contains(artist.kind ?? 0)) &&
        artists.map((artist) => '${artist.name}\u0000${artist.kind ?? 0}').toSet().length == artists.length &&
        (history ?? []).every((search) => search.query.isNotEmpty && search.usedAt.isFinite) &&
        (savedSearches ?? []).every((query) => query.isNotEmpty) &&
        (folderRules ?? []).every((rule) => names.contains(rule.folder) && rule.query.isNotEmpty) &&
        (recentWorks ?? []).every((recent) => recent.galleryId > 0 && recent.openedAt.isFinite);
    if (!valid) throw const LibraryBackupError();
  }

  void restore(SqlDatabase db, AppDatabase library) {
    final mapping = <String, int>{};
    for (final record in folders) {
      final row = db.row('SELECT * FROM folders WHERE name = ?', [record.name]);
      final folder = row == null ? Folder(name: record.name) : Folder.fromRow(row);
      folder.color = record.color ?? folder.color;
      folder.description = record.description ?? folder.description;
      folder.sourceGroupId = record.sourceGroupId ?? folder.sourceGroupId;
      AppDatabase.saveFolder(folder, db);
      final id = folder.id!;
      mapping[record.name] = id;
      db.execute('UPDATE folders SET sync_id = COALESCE(sync_id, ?) WHERE id = ?', [record.name == '미분류' ? 'unsorted' : uuidString(), id]);
    }
    // Swift's sort keeps equal elements in order; Dart's needs the tie broken.
    final indexed = folders.indexed.toList()
      ..sort((a, b) {
        final order = (a.$2.sortOrder ?? a.$1).compareTo(b.$2.sortOrder ?? b.$1);
        return order != 0 ? order : a.$1.compareTo(b.$1);
      });
    final importedOrder = indexed.map((entry) => mapping[entry.$2.name]).nonNulls.toList();
    final remaining = db.column<int>('SELECT id FROM folders ORDER BY sort_order, id').where((id) => !importedOrder.contains(id)).toList();
    for (final (position, id) in [...importedOrder, ...remaining].indexed) {
      db.execute('UPDATE folders SET sort_order = ? WHERE id = ?', [position, id]);
    }
    final order = db.column<String>('SELECT sync_id FROM folders WHERE sync_id IS NOT NULL ORDER BY sort_order, id');
    db.execute("INSERT OR REPLACE INTO library_order VALUES ('folders', ?)", [encodeSwiftJson(order)]);
    for (final record in works) {
      final existingRow = db.row('SELECT * FROM works WHERE gallery_id = ?', [record.galleryId]);
      final existing = existingRow == null ? null : Work.fromRow(existingRow);
      final work = existing ?? Work(galleryId: record.galleryId);
      work
        ..title = record.title ?? work.title
        ..artists = record.artists ?? work.artists
        ..note = record.note ?? work.note
        ..language = record.language ?? work.language
        ..type = record.type ?? work.type
        ..series = record.series ?? work.series
        ..groups = record.groups ?? work.groups
        ..tags = record.tags ?? work.tags
        ..bookmarkedAt = record.bookmarkedAt ?? work.bookmarkedAt
        ..publishedAt = record.publishedAt ?? work.publishedAt
        ..thumbPage = record.thumbPage ?? work.thumbPage
        ..site = work.site ?? record.site;
      AppDatabase.saveWork(work, db);
      var destinations = (record.folders ?? const <String>[]).map((name) => mapping[name]).nonNulls.toList();
      if (destinations.isEmpty && db.value<int>('SELECT COUNT(*) FROM folder_works WHERE work_id = ?', [work.id]) == 0) {
        destinations = [AppDatabase.unfiledFolder(db).id!];
      }
      for (final id in destinations) {
        db.execute('INSERT OR IGNORE INTO folder_works (folder_id, work_id, added_at) VALUES (?, ?, ?)', [id, work.id, work.bookmarkedAt]);
      }
      TasteStore.record(existing == null ? TasteEventKind.imported : TasteEventKind.metadata, library.comicItem(work.galleryId, work.tags), db);
    }
    for (final artist in artists) {
      db.execute(
        'INSERT INTO artists (name, kind, note, bookmarked_at) VALUES (?, ?, ?, ?) ON CONFLICT(name, kind) DO UPDATE SET note = COALESCE(excluded.note, artists.note)',
        [artist.name, artist.kind ?? 0, artist.note, iso8601()],
      );
    }
    for (final search in history ?? <MangaSearchRecord>[]) {
      db.execute('INSERT INTO search_history VALUES (?, ?) ON CONFLICT(query) DO UPDATE SET used_at = MAX(used_at, excluded.used_at)', [
        search.query,
        search.usedAt,
      ]);
    }
    for (final query in savedSearches ?? <String>[]) {
      db.execute('INSERT OR IGNORE INTO saved_searches VALUES (?)', [query]);
    }
    for (final record in folderRules ?? <MangaRuleRecord>[]) {
      final id = mapping[record.folder];
      if (id == null) continue;
      final sources = record.sources?.map((name) => mapping[name]).nonNulls.map((id) => AppDatabaseFolderRules.folderIdentity(id, db)).toList();
      AppDatabaseFolderRules.storeFolderRule(
        FolderRule(
          folder: AppDatabaseFolderRules.folderIdentity(id, db),
          query: record.query,
          excluded: record.excluded ?? '',
          isEnabled: record.isEnabled,
          sources: sources,
          includesOtherFolders: record.includesOtherFolders,
          keepsOriginal: record.keepsOriginal,
        ),
        db,
      );
    }
  }
}

/// Kept for callers which need to read/export the previous comics-only format.
abstract final class MangaLibraryBackup {
  static File export(AppDatabase database, {required Directory temporary}) =>
      File('${temporary.path}/tegnal-comics-${uuidString()}.json')
        ..writeAsBytesSync(encodeJson(MangaBackup.capture(database).toJson(), pretty: true), flush: true);
}
