import 'dart:io';

import '../core/storage/folder_rules.dart';
import '../core/support/l10n.dart';
import '../core/support/swift_json.dart';

/// Import metadata from older databases and backups is identified by its field role.
abstract final class MangaImportMetadata {
  static const groupIDKey = 'source_group_id';

  static String? legacyGroupIDKey(Iterable<String> keys) {
    final candidates = keys.where((key) => key != groupIDKey && key.endsWith('_group_id')).toList();
    return candidates.length == 1 ? candidates.first : null;
  }

  static Map<String, T> normalized<T>(Map<String, T> fields) {
    final key = legacyGroupIDKey(fields.keys);
    if (key == null) return fields;
    final result = {...fields};
    if (result[groupIDKey] == null) result[groupIDKey] = result[key] as T;
    result.remove(key);
    return result;
  }

  static int? groupID(Map<String, Object?> fields) {
    final value = normalized(fields)[groupIDKey];
    return value is int ? value : null;
  }
}

class Folder {
  Folder({
    this.id,
    required this.name,
    this.description,
    this.color = 4288585374,
    this.sortOrder = 0,
    String? createdAt,
    this.sourceGroupId,
    this.workCount = 0,
  }) : createdAt = createdAt ?? iso8601();

  int? id;
  String name;
  String? description;
  int color; // ARGB 32-bit integer
  int sortOrder;
  String createdAt;
  int? sourceGroupId;
  int workCount;

  /// Filled in by folder listings from the synced rules.
  bool isSmart = false;

  String get plainName => L10n.folderName(name);
  String get displayName => FolderRule.markedName(plainName, isSmart: isSmart);

  factory Folder.fromRow(Map<String, Object?> row, {int workCount = 0}) => Folder(
    id: row['id'] as int?,
    name: row['name'] as String,
    description: row['description'] as String?,
    color: row['color'] as int,
    sortOrder: row['sort_order'] as int,
    createdAt: row['created_at'] as String,
    sourceGroupId: row['source_group_id'] as int?,
    workCount: workCount,
  );

  /// Accepts the import field under its legacy name, as the native decoder does.
  factory Folder.fromJson(JsonObject json) {
    final legacy = MangaImportMetadata.legacyGroupIDKey(json.keys);
    return Folder(
      id: json.integerOrNull('id'),
      name: json.string('name'),
      description: json.stringOrNull('description'),
      color: json.integer('color'),
      sortOrder: json.integer('sort_order'),
      createdAt: json.string('created_at'),
      sourceGroupId: json.integerOrNull('source_group_id') ?? (legacy == null ? null : json.integerOrNull(legacy)),
    );
  }

  JsonObject toJson() => <String, Object?>{'name': name, 'color': color, 'sort_order': sortOrder, 'created_at': createdAt}
    ..putIfPresent('id', id)
    ..putIfPresent('description', description)
    ..putIfPresent('source_group_id', sourceGroupId);

  @override
  bool operator ==(Object other) =>
      other is Folder &&
      other.id == id &&
      other.name == name &&
      other.description == description &&
      other.color == color &&
      other.sortOrder == sortOrder &&
      other.createdAt == createdAt &&
      other.sourceGroupId == sourceGroupId &&
      other.workCount == workCount &&
      other.isSmart == isSmart;

  @override
  int get hashCode => Object.hash(id, name, color, sortOrder, sourceGroupId);
}

class Work {
  Work({
    this.id,
    required this.galleryId,
    this.title,
    this.artists,
    this.language,
    this.type,
    this.series,
    this.groups,
    this.tags,
    this.note,
    String? bookmarkedAt,
    this.publishedAt,
    this.lastOpenedAt,
    this.updatedAt,
    this.metadataSource,
    this.catalogMatched = false,
    this.thumbStatus = 'missing',
    this.thumbPath,
    this.thumbFailedAt,
    // The native initializer accepts a page but never stores it, so a new work is saved without one.
    this.thumbPage,
    this.site,
    List<Folder>? folders,
  }) : bookmarkedAt = bookmarkedAt ?? iso8601(),
       folders = folders ?? [];

  int? id;
  int galleryId;
  String? title;
  String? artists;
  String? language;
  String? type;
  String? series;
  String? groups;
  String? tags;
  String? note;
  String bookmarkedAt;
  String? publishedAt;
  String? lastOpenedAt;
  String? updatedAt;
  String? metadataSource;
  bool catalogMatched;
  String thumbStatus; // missing, ready, failed, gone
  String? thumbPath;
  String? thumbFailedAt;
  int? thumbPage;

  /// The comics site (its host) the work was saved from; unknown for older saves and imports.
  String? site;
  List<Folder> folders;

  bool get hasTitle => (title?.trim() ?? '').isNotEmpty;
  bool get hasThumb => thumbStatus == 'ready' && thumbPath != null && File(thumbPath!).existsSync();

  factory Work.fromRow(Map<String, Object?> row) => Work(
    id: row['id'] as int?,
    galleryId: row['gallery_id'] as int,
    title: row['title'] as String?,
    artists: row['artists'] as String?,
    language: row['language'] as String?,
    type: row['type'] as String?,
    series: row['series'] as String?,
    groups: row['groups'] as String?,
    tags: row['tags'] as String?,
    note: row['note'] as String?,
    bookmarkedAt: row['bookmarked_at'] as String,
    publishedAt: row['published_at'] as String?,
    lastOpenedAt: row['last_opened_at'] as String?,
    updatedAt: row['updated_at'] as String?,
    metadataSource: row['metadata_source'] as String?,
    catalogMatched: (row['catalog_matched'] as int? ?? 0) != 0,
    thumbStatus: row['thumb_status'] as String? ?? 'missing',
    thumbPath: row['thumb_path'] as String?,
    thumbFailedAt: row['thumb_failed_at'] as String?,
    // Records are read through their decoder, which fills a missing page with 1.
    thumbPage: row['thumb_page'] as int? ?? 1,
    site: row['site'] as String?,
  );

  static const columns = [
    'gallery_id', 'title', 'artists', 'language', 'type', 'series', 'groups', 'tags', 'note', 'bookmarked_at', //
    'published_at', 'last_opened_at', 'updated_at', 'metadata_source', 'catalog_matched', 'thumb_status', //
    'thumb_path', 'thumb_failed_at', 'thumb_page', 'site',
  ];

  List<Object?> get columnValues => [
    galleryId, title, artists, language, type, series, groups, tags, note, bookmarkedAt, //
    publishedAt, lastOpenedAt, updatedAt, metadataSource, catalogMatched, thumbStatus, //
    thumbPath, thumbFailedAt, thumbPage, site,
  ];
}

class CatalogWork {
  const CatalogWork({
    required this.id,
    this.title,
    this.type,
    this.language,
    this.artists,
    this.groups,
    this.series,
    this.characters,
    this.tags,
    this.published,
  });

  final int id; // gallery_id
  final String? title;
  final String? type;
  final String? language;
  final String? artists;
  final String? groups;
  final String? series;
  final String? characters;
  final String? tags;
  final String? published;

  factory CatalogWork.fromRow(Map<String, Object?> row) => CatalogWork(
    id: row['id'] as int,
    title: row['title'] as String?,
    type: row['type'] as String?,
    language: row['language'] as String?,
    artists: row['artists'] as String?,
    groups: row['groups'] as String?,
    series: row['series'] as String?,
    characters: row['characters'] as String?,
    tags: row['tags'] as String?,
    published: row['published'] as String?,
  );
}

class ArtistMemo {
  ArtistMemo({this.id, required this.name, this.kind = 0, this.note, this.folderId, String? bookmarkedAt}) : bookmarkedAt = bookmarkedAt ?? iso8601();

  int? id;
  String name;
  int kind; // SavedCollectionKind.mangaKind; legacy artist = 0, group = 1
  String? note;
  int? folderId;
  String bookmarkedAt;

  factory ArtistMemo.fromRow(Map<String, Object?> row) => ArtistMemo(
    id: row['id'] as int?,
    name: row['name'] as String,
    kind: row['kind'] as int,
    note: row['note'] as String?,
    folderId: row['folder_id'] as int?,
    bookmarkedAt: row['bookmarked_at'] as String,
  );
}

class SaveResult {
  const SaveResult({required this.works, required this.created, required this.duplicates});
  final List<Work> works;
  final int created;
  final int duplicates;
}

/// Persisted kinds retain the original artist/group values used by imports and sync.
enum SavedCollectionKind {
  tag,
  artist,
  series,
  character,
  group,
  language,
  type,
  female,
  male,
  metadata,
  search,
  history;

  String get rawValue => name;
  static SavedCollectionKind? fromRawValue(String value) {
    for (final kind in values) {
      if (kind.name == value) return kind;
    }
    return null;
  }

  static String identity(String name) => name.replaceAll('_', ' ').trim().toLowerCase();

  int? get mangaKind => switch (this) {
    artist => 0,
    group => 1,
    tag => 2,
    series => 3,
    character => 4,
    language => 5,
    type => 6,
    female => 7,
    male => 8,
    metadata => 9,
    search || history => null,
  };

  String get title => switch (this) {
    tag => 'Tags',
    artist => 'Artists',
    series => 'Series',
    character => 'Characters',
    group => 'Groups',
    language => 'Language',
    type => 'Type',
    female => 'Female Tags',
    male => 'Male Tags',
    metadata => 'Metadata Tags',
    search => 'Saved Searches',
    history => 'Search History',
  };

  String? get namespace => switch (this) {
    tag || search || history => null,
    metadata => 'meta',
    _ => name,
  };

  String normalized(String name) {
    var value = name.trim();
    if (this == search || this == history) return value;
    final namespace = this.namespace;
    if (namespace != null && value.startsWith('$namespace:')) value = value.substring(namespace.length + 1);
    return value.replaceAll(' ', '_');
  }

  String query(String name, {required bool manga}) {
    final namespace = this.namespace;
    if (!manga || namespace == null || name.contains(':')) return name;
    return '$namespace:${name.replaceAll(' ', '_')}';
  }
}

/// The first five entries are a preview of the same persistent order used in More.
abstract final class SavedCollectionOrdering {
  static List<String> resolve(List<String> names, {required List<String> preferred}) {
    final available = names.toSet();
    final seen = <String>{};
    return [...preferred, ...names].where((name) => available.contains(name) && seen.add(name)).toList();
  }

  static List<String> moved(List<String> names, {required String source, required String target}) {
    final from = names.indexOf(source), to = names.indexOf(target);
    if (source == target || from < 0 || to < 0) return names;
    return [...names]
      ..removeAt(from)
      ..insert(to, source);
  }

  static List<String> preview(List<String> names) => names.take(5).toList();
  static bool showsMore(int count) => count >= 5;
}
