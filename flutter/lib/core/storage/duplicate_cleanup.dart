import 'dart:convert';

import '../../domain/models.dart';
import '../booru/booru_account.dart';
import '../booru/booru_store.dart';
import '../content/site_favorites_sync.dart';
import '../support/preferences.dart';
import '../support/swift_json.dart';
import 'app_database.dart';
import 'folder_rules.dart';
import 'library_maintenance.dart';

/// What makes two saved works the same work.
enum DuplicateMatch {
  /// The same work number: one work saved in several folders.
  sameNumber,

  /// The title without its bracketed parts (circle, parody, language, translator) and the same artist.
  sameTitle,

  /// The same full title, artist, language and type.
  exact;

  String get title => switch (this) {
    sameNumber => 'Same Work Number',
    sameTitle => 'Same Title and Artist',
    exact => 'Exact Match',
  };
}

/// Which copy stays once folders and language have had their say.
enum DuplicateKeep {
  oldestSaved,
  newestSaved,
  newestNumber,
  oldestNumber,
  mostPages,
  recentlyRead,
  largestImage;

  String get title => switch (this) {
    oldestSaved => 'Saved First',
    newestSaved => 'Saved Last',
    newestNumber => 'Newest Upload',
    oldestNumber => 'Oldest Upload',
    mostPages => 'Most Pages',
    recentlyRead => 'Read Most Recently',
    largestImage => 'Largest Image',
  };

  static List<DuplicateKeep> choices({required bool images, DuplicateMatch match = DuplicateMatch.sameTitle}) {
    if (images) return const [oldestSaved, newestSaved, newestNumber, oldestNumber, largestImage];
    // One work in several folders: only when it went into each folder tells them apart.
    if (match == DuplicateMatch.sameNumber) return const [oldestSaved, newestSaved];
    return const [oldestSaved, newestSaved, newestNumber, oldestNumber, mostPages, recentlyRead];
  }
}

/// `DuplicateCleanupOptions`: how duplicates are found and which copy stays, kept between visits,
/// one set for each mode.
class DuplicateCleanupOptions {
  DuplicateCleanupOptions({
    this.match = DuplicateMatch.sameNumber,
    this.acrossLanguages = false,
    this.keep = DuplicateKeep.oldestSaved,
    this.preferredLanguage = '',
    this.useFolderOrder = true,
    List<String>? folderOrder,
    this.combine = true,
    this.removeFromWebsite = false,
  }) : folderOrder = folderOrder ?? const [];

  final DuplicateMatch match;

  /// A translation of a work counts as the same work.
  final bool acrossLanguages;

  final DuplicateKeep keep;

  /// The keep rule, or saved first where the chosen one doesn't apply to this match.
  DuplicateKeep keepFor({required bool images}) => DuplicateKeep.choices(images: images, match: match).contains(keep) ? keep : DuplicateKeep.oldestSaved;

  /// A copy in this language stays first; empty for any.
  final String preferredLanguage;

  /// A copy in a folder higher in [folderOrder] stays first.
  final bool useFolderOrder;

  /// Folder keys, highest first; folders not listed follow in their usual order.
  final List<String> folderOrder;

  /// The kept copy takes the folders and notes of the copies removed.
  final bool combine;

  /// Removed copies that a signed-in website keeps as favorites leave it too.
  final bool removeFromWebsite;

  DuplicateCleanupOptions copyWith({
    DuplicateMatch? match,
    bool? acrossLanguages,
    DuplicateKeep? keep,
    String? preferredLanguage,
    bool? useFolderOrder,
    List<String>? folderOrder,
    bool? combine,
    bool? removeFromWebsite,
  }) => DuplicateCleanupOptions(
    match: match ?? this.match,
    acrossLanguages: acrossLanguages ?? this.acrossLanguages,
    keep: keep ?? this.keep,
    preferredLanguage: preferredLanguage ?? this.preferredLanguage,
    useFolderOrder: useFolderOrder ?? this.useFolderOrder,
    folderOrder: folderOrder ?? this.folderOrder,
    combine: combine ?? this.combine,
    removeFromWebsite: removeFromWebsite ?? this.removeFromWebsite,
  );

  Map<String, Object?> toJson() => {
    'match': match.name,
    'acrossLanguages': acrossLanguages,
    'keep': keep.name,
    'preferredLanguage': preferredLanguage,
    'useFolderOrder': useFolderOrder,
    'folderOrder': folderOrder,
    'combine': combine,
    'removeFromWebsite': removeFromWebsite,
  };

  /// Options a save didn't have take their defaults.
  static DuplicateCleanupOptions fromJson(Object? json) {
    if (json is! Map) return DuplicateCleanupOptions();
    final standard = DuplicateCleanupOptions();
    T pick<T>(String key, T fallback) => json[key] is T ? json[key] as T : fallback;
    return DuplicateCleanupOptions(
      match: DuplicateMatch.values.where((value) => value.name == json['match']).firstOrNull ?? standard.match,
      acrossLanguages: pick('acrossLanguages', standard.acrossLanguages),
      keep: DuplicateKeep.values.where((value) => value.name == json['keep']).firstOrNull ?? standard.keep,
      preferredLanguage: pick('preferredLanguage', standard.preferredLanguage),
      useFolderOrder: pick('useFolderOrder', standard.useFolderOrder),
      folderOrder: json['folderOrder'] is List ? (json['folderOrder'] as List).whereType<String>().toList() : standard.folderOrder,
      combine: pick('combine', standard.combine),
      removeFromWebsite: pick('removeFromWebsite', standard.removeFromWebsite),
    );
  }

  static String _key({required bool images}) => images ? 'booru.duplicateCleanup' : 'library.duplicateCleanup';

  static DuplicateCleanupOptions load(Preferences preferences, {required bool images}) {
    final text = preferences.string(_key(images: images));
    if (text == null) return DuplicateCleanupOptions();
    try {
      return fromJson(jsonDecode(text));
    } on FormatException {
      return DuplicateCleanupOptions();
    }
  }

  void save(Preferences preferences, {required bool images}) => preferences.set(_key(images: images), jsonEncode(toJson()));

  @override
  bool operator ==(Object other) => other is DuplicateCleanupOptions && jsonEncode(other.toJson()) == jsonEncode(toJson());
  @override
  int get hashCode => jsonEncode(toJson()).hashCode;
}

/// One saved copy of a work or an image, as the cleanup compares them.
class DuplicateCopy {
  const DuplicateCopy({
    required this.id,
    required this.number,
    required this.title,
    required this.savedAt,
    required this.lastOpenedAt,
    required this.folders,
    required this.language,
    required this.size,
    this.thumbnailPath,
    this.previewURL,
    this.server,
  });

  /// The work number, or the image's `server:post` id.
  final String id;

  /// The work number or post number; a larger one was uploaded later.
  final int number;
  final String title;
  final DateTime? savedAt;
  final DateTime? lastOpenedAt;

  /// The folders it is saved in, by their keys.
  final List<String> folders;
  final String language;

  /// Pages for a work; pixels for an image.
  final int size;
  final String? thumbnailPath;
  final String? previewURL;

  /// The image's server, shown beside it.
  final String? server;
}

/// Copies of one work or image, with the one that stays. For one work saved in several folders
/// ([workNumber]), each copy is one of its folders, and the folder kept is where it stays.
class DuplicateGroup {
  const DuplicateGroup({required this.id, required this.title, required this.copies, required this.keeperID, this.workNumber});
  final String id;
  final String title;
  final List<DuplicateCopy> copies;
  final String keeperID;
  final int? workNumber;

  DuplicateCopy? get keeper => copies.where((copy) => copy.id == keeperID).firstOrNull;
  List<DuplicateCopy> get removals => copies.where((copy) => copy.id != keeperID).toList();

  DuplicateGroup keeping(String id) => DuplicateGroup(id: this.id, title: title, copies: copies, keeperID: id, workNumber: workNumber);
}

/// `DuplicateFinder`: finds duplicates and chooses which copy stays, with no database or screen of its own.
abstract final class DuplicateFinder {
  static const _pairs = {'[': ']', '(': ')', '{': '}', '【': '】', '（': '）', '［': '］', '｛': '｝'};

  /// The title without bracketed parts — circle, parody, language, translator, version — in lower
  /// case with punctuation and extra spaces dropped. A title that is all brackets keeps them.
  static String coreTitle(String title) {
    final stack = <String>[];
    final outside = StringBuffer();
    for (final rune in title.runes) {
      final character = String.fromCharCode(rune);
      if (_pairs[character] case final close?) {
        stack.add(close);
        continue;
      }
      if (stack.isNotEmpty && character == stack.last) {
        stack.removeLast();
        continue;
      }
      if (stack.isEmpty) outside.write(character);
    }
    String simplified(String text) =>
        text.toLowerCase().replaceAll(RegExp(r'[^\p{L}\p{N}]+', unicode: true), ' ').split(' ').where((part) => part.isNotEmpty).join(' ');
    final core = simplified(outside.toString());
    return core.isEmpty ? simplified(title) : core;
  }

  static List<String> _names(String? text) => (text ?? '').split(',').map((name) => name.trim().toLowerCase()).where((name) => name.isNotEmpty).toList();

  /// What two works must share to be the same work; null leaves a work out, as one without a title or artist.
  static String? key(Work work, DuplicateCleanupOptions options) {
    if (options.match == DuplicateMatch.exact) return LibraryMaintenance.duplicateKey(work);
    final title = work.title;
    final artists = _names(work.artists)..sort();
    final groups = _names(work.groups)..sort();
    final person = artists.firstOrNull ?? groups.firstOrNull;
    if (title == null || title.trim().isEmpty || person == null) return null;
    final core = coreTitle(title);
    if (core.isEmpty) return null;
    return [core, person, if (!options.acrossLanguages) (work.language ?? '').toLowerCase()].join('\u0000');
  }

  static DuplicateCopy copy(Work work, Map<int, String> folderKeys) => DuplicateCopy(
    id: '${work.galleryId}',
    number: work.galleryId,
    title: work.title ?? '${work.galleryId}',
    savedAt: DateTime.tryParse(work.bookmarkedAt),
    lastOpenedAt: work.lastOpenedAt == null ? null : DateTime.tryParse(work.lastOpenedAt!),
    folders: [for (final folder in work.folders) ?folderKeys[folder.id]],
    language: (work.language ?? '').toLowerCase(),
    size: work.pageCount ?? 0,
    thumbnailPath: work.thumbStatus == 'ready' ? work.thumbPath : null,
  );

  /// Saved works that are the same work, each with the copy the options keep.
  static List<DuplicateGroup> comics(
    List<Work> works, {
    required Map<int, String> folderKeys,
    required Map<String, int> folderRank,
    required DuplicateCleanupOptions options,
  }) {
    final grouped = <String, List<Work>>{};
    for (final work in works) {
      final key = DuplicateFinder.key(work, options);
      if (key != null) (grouped[key] ??= []).add(work);
    }
    return [
      for (final MapEntry(:key, :value) in grouped.entries)
        if (value.length > 1)
          () {
            final copies = [for (final work in value) copy(work, folderKeys)];
            final kept = keeper(copies, folderRank, options);
            return DuplicateGroup(id: key, title: copies.firstWhere((copy) => copy.id == kept).title, copies: _order(copies, kept), keeperID: kept);
          }(),
    ]..sort((a, b) => localizedStandardCompare(a.title, b.title));
  }

  /// Saved images with the same original file, each with the copy the options keep.
  static List<DuplicateGroup> images(
    List<FavoriteRecord> records, {
    required Map<String, String> serverNames,
    required Map<String, int> folderRank,
    required DuplicateCleanupOptions options,
  }) {
    final grouped = <String, List<FavoriteRecord>>{};
    for (final record in records) {
      final key = LibraryMaintenance.postDuplicateKey(record.post);
      if (key != null) (grouped[key] ??= []).add(record);
    }
    final groups = [
      for (final MapEntry(:key, :value) in grouped.entries)
        if (value.length > 1)
          () {
            final copies = [
              for (final record in value)
                DuplicateCopy(
                  id: record.post.id,
                  number: record.post.postID,
                  title: record.post.artists.firstOrNull ?? record.post.tags.take(3).join(' '),
                  savedAt: DateTime.fromMillisecondsSinceEpoch((record.savedAt * 1000).round()),
                  lastOpenedAt: null,
                  folders: [record.folderID],
                  language: '',
                  size: record.post.width * record.post.height,
                  previewURL: record.post.previewURL,
                  server: serverNames[record.post.serverID] ?? record.post.serverID,
                ),
            ];
            final kept = keeper(copies, folderRank, options);
            return DuplicateGroup(id: key, title: copies.first.title, copies: _order(copies, kept), keeperID: kept);
          }(),
    ];
    final far = DateTime.fromMillisecondsSinceEpoch(0);
    return groups..sort((a, b) => (b.copies.first.savedAt ?? far).compareTo(a.copies.first.savedAt ?? far));
  }

  /// The kept copy first, then the others as they were saved.
  static List<DuplicateCopy> _order(List<DuplicateCopy> copies, String keeper) {
    final far = DateTime.fromMillisecondsSinceEpoch(0);
    return [...copies]..sort((a, b) {
      if ((a.id == keeper) != (b.id == keeper)) return a.id == keeper ? -1 : 1;
      return (a.savedAt ?? far).compareTo(b.savedAt ?? far);
    });
  }

  /// The copy that stays: one in the highest folder, then one in the preferred language, then the
  /// keep rule; the smaller number settles a tie.
  static String keeper(List<DuplicateCopy> copies, Map<String, int> rank, DuplicateCleanupOptions options) {
    const last = 1 << 62;
    int folderRank(DuplicateCopy copy) => copy.folders.map((key) => rank[key] ?? last).fold(last, (a, b) => a < b ? a : b);
    final language = options.preferredLanguage.toLowerCase();
    final early = DateTime.fromMillisecondsSinceEpoch(0), late = DateTime(9999);
    final keep = options.keepFor(images: copies.any((copy) => copy.server != null));
    int compare(DuplicateCopy a, DuplicateCopy b) {
      if (options.useFolderOrder && folderRank(a) != folderRank(b)) return folderRank(a).compareTo(folderRank(b));
      if (language.isNotEmpty && (a.language == language) != (b.language == language)) return a.language == language ? -1 : 1;
      final rule = switch (keep) {
        DuplicateKeep.oldestSaved => (a.savedAt ?? late).compareTo(b.savedAt ?? late),
        DuplicateKeep.newestSaved => (b.savedAt ?? early).compareTo(a.savedAt ?? early),
        DuplicateKeep.newestNumber => b.number.compareTo(a.number),
        DuplicateKeep.oldestNumber => a.number.compareTo(b.number),
        DuplicateKeep.mostPages || DuplicateKeep.largestImage => b.size.compareTo(a.size),
        DuplicateKeep.recentlyRead => (b.lastOpenedAt ?? early).compareTo(a.lastOpenedAt ?? early),
      };
      return rule != 0 ? rule : a.number.compareTo(b.number);
    }

    return copies.reduce((a, b) => compare(a, b) <= 0 ? a : b).id;
  }

  /// One work saved in several folders, each folder a copy: it stays in the folder the options
  /// prefer. [fixed] folders (kept with website favorites, smart folders) are left as they are.
  static List<DuplicateGroup> placements(
    List<Work> works, {
    required Map<int, Map<int, String>> addedAt,
    required Map<int, String> folderKeys,
    required Map<String, String> folderNames,
    required Map<String, int> folderRank,
    required Set<String> fixed,
    required DuplicateCleanupOptions options,
  }) {
    final groups = <DuplicateGroup>[];
    for (final work in works) {
      final folders = [
        for (final folder in work.folders)
          if (folderKeys[folder.id] case final key? when !fixed.contains(key)) (id: folder.id!, key: key),
      ];
      if (folders.length < 2) continue;
      final added = addedAt[work.galleryId] ?? const <int, String>{};
      final copies = [
        for (final folder in folders)
          DuplicateCopy(
            id: '${work.galleryId}@${folder.key}',
            number: work.galleryId,
            title: folderNames[folder.key] ?? folder.key,
            savedAt: added[folder.id] == null ? null : DateTime.tryParse(added[folder.id]!),
            lastOpenedAt: null,
            folders: [folder.key],
            language: '',
            size: 0,
            thumbnailPath: work.thumbStatus == 'ready' ? work.thumbPath : null,
          ),
      ];
      final kept = keeper(copies, folderRank, options);
      groups.add(
        DuplicateGroup(
          id: 'number:${work.galleryId}',
          title: work.title ?? '${work.galleryId}',
          copies: _order(copies, kept),
          keeperID: kept,
          workNumber: work.galleryId,
        ),
      );
    }
    return groups..sort((a, b) => localizedStandardCompare(a.title, b.title));
  }

  /// Each folder's place: the chosen order first, then the others in [standard] order.
  static Map<String, int> rank({required List<String> order, required List<String> standard}) {
    final result = <String, int>{};
    final known = standard.toSet();
    for (final key in [...order, ...standard]) {
      if (!result.containsKey(key) && known.contains(key)) result[key] = result.length;
    }
    return result;
  }
}

/// What a cleanup changed, so it can be put back.
class DuplicateUndo {
  /// Removed works, their folders, and the kept works' folders, notes and reading times before.
  final works = <Map<String, Object?>>[];
  final memberships = <(int workID, int folderID, String addedAt)>[];
  final keepers = <(int workID, List<(int folderID, String addedAt)> memberships, String? note, String? lastOpenedAt)>[];

  /// Folder memberships taken from works saved in several folders.
  final tidied = <(int workID, int folderID, String addedAt)>[];

  /// Removed images, as they were saved.
  final images = <FavoriteRecord>[];

  /// Website favorites left alone before, by website or server.
  final siteIgnored = <String, Set<int>>{};
  final serverIgnored = <String, Set<int>>{};
  int removedCount = 0;
  int tidiedCount = 0;
}

/// `DuplicateCleaner`: carries a cleanup out on the library, and puts it back.
abstract final class DuplicateCleaner {
  /// Removes each group's other copies. With [combine] the kept copy takes their folders (apart from
  /// [websiteFolders]) and notes. Removed works a website keeps as favorites stay there unless
  /// [removeFromWebsite].
  static DuplicateUndo applyComics(
    List<DuplicateGroup> chosen, {
    required bool combine,
    required bool removeFromWebsite,
    Set<int> websiteFolders = const {},
    required AppDatabase database,
    SiteFavoriteFolders? sites,
  }) {
    final undo = DuplicateUndo();
    final placements = chosen.where((group) => group.workNumber != null).toList();
    final groups = chosen.where((group) => group.workNumber == null).toList();
    final removed = {
      for (final group in groups)
        for (final copy in group.removals) ?int.tryParse(copy.id),
    };
    if (!removeFromWebsite && sites != null) _leaveOnWebsites(removed, sites, undo);
    database.dbWriter.write((db) {
      Map<String, Object?>? fetch(int galleryId) => db.rows('SELECT * FROM works WHERE gallery_id = ?', [galleryId]).firstOrNull;
      for (final group in groups) {
        final keeperNumber = int.tryParse(group.keeperID);
        final keeperRow = keeperNumber == null ? null : fetch(keeperNumber);
        if (keeperRow == null) continue;
        final keeperID = keeperRow['id'] as int;
        final before = db.rows('SELECT folder_id, added_at FROM folder_works WHERE work_id = ?', [keeperID]);
        undo.keepers.add((
          keeperID,
          [for (final row in before) (row['folder_id'] as int, row['added_at'] as String)],
          keeperRow['note'] as String?,
          keeperRow['last_opened_at'] as String?,
        ));
        final note = keeperRow['note'] as String?;
        final notes = [if (note != null && note.isNotEmpty) note];
        var lastOpened = keeperRow['last_opened_at'] as String?;
        for (final copy in group.removals) {
          final number = int.tryParse(copy.id);
          final row = number == null ? null : fetch(number);
          if (row == null) continue;
          final workID = row['id'] as int;
          final folders = db.rows('SELECT folder_id, added_at FROM folder_works WHERE work_id = ?', [workID]);
          undo.works.add(row);
          for (final folder in folders) {
            undo.memberships.add((workID, folder['folder_id'] as int, folder['added_at'] as String));
          }
          if (combine) {
            for (final folder in folders) {
              if (websiteFolders.contains(folder['folder_id'])) continue;
              db.execute('INSERT INTO folder_works (folder_id, work_id, added_at) VALUES (?, ?, ?) ON CONFLICT(folder_id, work_id) DO NOTHING', [
                folder['folder_id'],
                keeperID,
                folder['added_at'],
              ]);
            }
            final other = row['note'] as String?;
            if (other != null && other.isNotEmpty && !notes.contains(other)) notes.add(other);
          }
          final opened = row['last_opened_at'] as String?;
          if (opened != null && opened.compareTo(lastOpened ?? '') > 0) lastOpened = opened;
          db.execute('DELETE FROM folder_works WHERE work_id = ?', [workID]);
          db.execute('DELETE FROM works WHERE id = ?', [workID]);
          undo.removedCount += 1;
        }
        AppDatabaseFolderRules.leaveUnfiled(keeperID, db);
        db.execute('UPDATE works SET note = ?, last_opened_at = ? WHERE id = ?', [notes.isEmpty ? note : notes.join('\n\n'), lastOpened, keeperID]);
      }
      for (final group in placements) {
        final workID = db.value<int>('SELECT id FROM works WHERE gallery_id = ?', [group.workNumber]);
        if (workID == null) continue;
        for (final copy in group.removals) {
          final folderID = int.tryParse(copy.folders.firstOrNull ?? '');
          if (folderID == null) continue;
          final addedAt = db.value<String>('SELECT added_at FROM folder_works WHERE work_id = ? AND folder_id = ?', [workID, folderID]);
          if (addedAt == null) continue;
          db.execute('DELETE FROM folder_works WHERE work_id = ? AND folder_id = ?', [workID, folderID]);
          undo.tidied.add((workID, folderID, addedAt));
        }
        undo.tidiedCount += 1;
      }
    });
    return undo;
  }

  /// When each saved work went into each of its folders, by work number and folder.
  static Map<int, Map<int, String>> folderTimes(AppDatabase database) => database.dbWriter.read((db) {
    final result = <int, Map<int, String>>{};
    for (final row in db.rows('SELECT w.gallery_id, fw.folder_id, fw.added_at FROM folder_works fw JOIN works w ON w.id = fw.work_id')) {
      (result[row['gallery_id'] as int] ??= {})[row['folder_id'] as int] = row['added_at'] as String;
    }
    return result;
  });

  /// Removes each group's other images. Removed images a server keeps as favorites stay there unless
  /// [removeFromWebsite].
  static DuplicateUndo applyImages(
    List<DuplicateGroup> groups, {
    required List<FavoriteRecord> records,
    required bool removeFromWebsite,
    required BooruStore store,
    BooruAccountSync? accounts,
  }) {
    final undo = DuplicateUndo();
    final removed = {
      for (final group in groups)
        for (final copy in group.removals) copy.id,
    };
    undo.images.addAll(records.where((record) => removed.contains(record.post.id)));
    final posts = [for (final record in undo.images) record.post];
    if (accounts != null) {
      for (final serverID in {for (final post in posts) post.serverID}) {
        if (accounts.accounts.favorites.state(serverID) case final state?) undo.serverIgnored[serverID] = {...state.ignored};
      }
      accounts.removeFavorites(posts, keepOnServer: !removeFromWebsite);
    } else {
      store.removeFavorites(posts);
    }
    undo.removedCount = posts.length;
    return undo;
  }

  /// Leaves removed works alone on every synced website, remembering what each left alone before.
  static void _leaveOnWebsites(Set<int> ids, SiteFavoriteFolders sites, DuplicateUndo undo) {
    for (final site in sites.syncedSites) {
      final state = sites.state(site);
      if (state == null) continue;
      final kept = ids.where((id) => state.baseline?.containsKey(id) ?? false);
      if (kept.isEmpty) continue;
      undo.siteIgnored[site] = {...state.ignored};
      state.ignored.addAll(kept);
      sites.setState(state, site);
    }
  }

  /// Puts a cleanup back: removed copies return with their folders, and kept copies get their
  /// folders, notes and reading times back.
  static void undo(DuplicateUndo undo, {required AppDatabase database, BooruStore? images, BooruAccountSync? accounts, SiteFavoriteFolders? sites}) {
    if (undo.works.isNotEmpty || undo.tidied.isNotEmpty || undo.keepers.isNotEmpty) {
      database.dbWriter.write((db) {
        for (final row in undo.works) {
          if (db.value<int>('SELECT id FROM works WHERE id = ?', [row['id']]) != null) continue;
          final columns = row.keys.toList();
          db.execute('INSERT INTO works (${columns.join(', ')}) VALUES (${List.filled(columns.length, '?').join(', ')})', [
            for (final column in columns) row[column],
          ]);
        }
        for (final (workID, folderID, addedAt) in [...undo.memberships, ...undo.tidied]) {
          db.execute('INSERT OR IGNORE INTO folder_works (folder_id, work_id, added_at) VALUES (?, ?, ?)', [folderID, workID, addedAt]);
        }
        for (final (workID, memberships, note, lastOpenedAt) in undo.keepers) {
          db.execute('DELETE FROM folder_works WHERE work_id = ?', [workID]);
          for (final (folderID, addedAt) in memberships) {
            db.execute('INSERT INTO folder_works (folder_id, work_id, added_at) VALUES (?, ?, ?)', [folderID, workID, addedAt]);
          }
          db.execute('UPDATE works SET note = ?, last_opened_at = ? WHERE id = ?', [note, lastOpenedAt, workID]);
        }
      });
    }
    if (sites != null) {
      for (final MapEntry(key: site, value: ignored) in undo.siteIgnored.entries) {
        final state = sites.state(site);
        if (state == null) continue;
        state.ignored
          ..clear()
          ..addAll(ignored);
        sites.setState(state, site);
      }
    }
    if (images != null && undo.images.isNotEmpty) restoreFavorites(images, undo.images);
    if (accounts != null) {
      for (final MapEntry(key: serverID, value: ignored) in undo.serverIgnored.entries) {
        final state = accounts.accounts.favorites.state(serverID);
        if (state == null) continue;
        state.ignored
          ..clear()
          ..addAll(ignored);
        accounts.accounts.favorites.setState(state, serverID);
      }
    }
  }

  /// Saves images back as they were: the same folder and moment.
  static void restoreFavorites(BooruStore store, List<FavoriteRecord> records) {
    store.database.write((db) {
      for (final record in records) {
        db.execute('INSERT OR IGNORE INTO favorites (server_id, post_id, payload, saved_at, folder_id) VALUES (?, ?, ?, ?, ?)', [
          record.post.serverID,
          record.post.postID,
          encodeSwiftJson(record.post.toJson()),
          record.savedAt,
          record.folderID,
        ]);
      }
    });
    store.revision += 1;
  }
}

/// A language as the library names it, such as "korean", shown in the app's language.
String libraryLanguageTitle(String code) => code.isEmpty ? code : code[0].toUpperCase() + code.substring(1);
