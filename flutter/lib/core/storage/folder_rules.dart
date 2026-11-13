import 'dart:convert';
import 'dart:typed_data';

import '../../domain/models.dart';
import '../booru/booru_models.dart';
import '../booru/booru_store.dart';
import '../support/preferences.dart';
import '../support/sql_database.dart';
import '../support/swift_json.dart';
import 'app_database.dart';
import 'work_query.dart';

/// A smart folder's rule. A folder has at most one, kept in its own row so sync merges
/// edits folder by folder, and folders are named by their sync identity.
class FolderRule {
  FolderRule({required this.folder, required this.query, this.excluded = '', this.isEnabled, this.sources, this.includesOtherFolders, this.keepsOriginal});

  static const keyPrefix = 'folder_rule.';
  String folder;
  String query;
  String excluded;

  /// Switching a rule off keeps its tags. Optional so rules saved before this still decode.
  bool? isEnabled;

  /// Folders the rule reads from. Absent follows wherever new saves land.
  List<String>? sources;

  /// Reads every folder, including ones made later.
  bool? includesOtherFolders;

  /// Comics only: a matching work also stays in the folder it came from. Rules saved before
  /// this choice existed copied, so absent reads as true; the editor always writes it.
  /// Images are in one folder at a time and always move.
  bool? keepsOriginal;

  String get id => folder;
  bool get isActive => isEnabled != false;
  bool get copies => keepsOriginal ?? true;
  WorkQuery get workQuery => WorkQuery(query, excluding: excluded);

  /// The mark stays with the name, so every list of folders shows it.
  static String markedName(String name, {required bool isSmart}) => isSmart ? '$name ✦' : name;

  /// Parsed once, because a library is scanned on every edit of the tags.
  bool Function(BooruPost post) get postMatcher {
    if (workQuery.isEmpty) return (_) => false;
    final required = BooruBlacklist(query.replaceAll(',', ' '));
    final refused = BooruBlacklist(swiftSplit(excluded, (character) => isWhitespace(character) || character == ',').join('\n'));
    return (post) => required.contains(post) && !refused.contains(post);
  }

  factory FolderRule.fromJson(JsonObject json) => FolderRule(
    folder: json.string('folder'),
    query: json.string('query'),
    excluded: json.string('excluded'),
    isEnabled: json.booleanOrNull('isEnabled'),
    sources: json.stringsOrNull('sources'),
    includesOtherFolders: json.booleanOrNull('includesOtherFolders'),
    keepsOriginal: json.booleanOrNull('keepsOriginal'),
  );

  JsonObject toJson() => <String, Object?>{'folder': folder, 'query': query, 'excluded': excluded}
    ..putIfPresent('isEnabled', isEnabled)
    ..putIfPresent('sources', sources)
    ..putIfPresent('includesOtherFolders', includesOtherFolders)
    ..putIfPresent('keepsOriginal', keepsOriginal);

  /// A row that cannot be read, say from a newer version, is skipped.
  static FolderRule? tryDecode(List<int> data) {
    try {
      return FolderRule.fromJson(decodeJsonObject(data));
    } on Object {
      return null;
    }
  }

  @override
  bool operator ==(Object other) => other is FolderRule && encodeJsonString(toJson()) == encodeJsonString(other.toJson());

  @override
  int get hashCode => encodeJsonString(toJson()).hashCode;
}

class SmartFolderChoice {
  const SmartFolderChoice({required this.id, required this.name, required this.canBeSmart});
  final String id;
  final String name;
  final bool canBeSmart;

  @override
  bool operator ==(Object other) => other is SmartFolderChoice && other.id == id && other.name == name && other.canBeSmart == canBeSmart;
  @override
  int get hashCode => Object.hash(id, name, canBeSmart);
}

/// What a smart folder needs from either library.
abstract interface class SmartFolderLibrary {
  List<SmartFolderChoice> folderChoices();

  /// Where new saves land, which is what a rule reads unless it says otherwise.
  Set<String> defaultRuleSources();
  FolderRule? rule(String forFolder);
  List<FolderRule> smartRules();
  int matchingCount(FolderRule rule);

  /// Saved works that match the tags but sit in folders the rule does not look in.
  int matchingCountElsewhere(FolderRule rule);
  String createRuleFolder(String named);
  void saveRule(FolderRule rule);
  void deleteRule(String forFolder);
  void fill(FolderRule rule);
}

abstract final class LibrarySavePreferences {
  static const defaultFolderKey = 'library.defaultFolderIdentity';
  static const legacyDefaultFolderKey = 'library.defaultFolder';
  static const rulesEnabledKey = 'library.folderRules';
  static bool rulesEnabled(Preferences defaults) => defaults.boolean(rulesEnabledKey) ?? true;

  /// Row IDs differ between devices, so an older local choice moves to the folder's identity.
  static String? defaultFolderIdentity(SqlDatabase db, Preferences defaults) {
    final identity = defaults.string(defaultFolderKey);
    if (identity != null) return identity;
    final legacy = defaults.integer(legacyDefaultFolderKey);
    if (legacy == 0) return null;
    final found = db.value<String>('SELECT sync_id FROM folders WHERE id = ?', [legacy]);
    if (found == null) return null;
    defaults.set(defaultFolderKey, found);
    defaults.remove(legacyDefaultFolderKey);
    return found;
  }
}

extension AppDatabaseFolderRules on AppDatabase {
  static const _legacyRulesKey = 'folder_rules';

  /// A row that cannot be read, say from a newer version, never blocks a save.
  static List<FolderRule> fetchFolderRules(SqlDatabase db) =>
      db.column<Uint8List>('SELECT value FROM library_order WHERE key GLOB ?', ['${FolderRule.keyPrefix}*']).map(FolderRule.tryDecode).nonNulls.toList();

  static void storeFolderRule(FolderRule rule, SqlDatabase db) =>
      db.execute('INSERT OR REPLACE INTO library_order VALUES (?, ?)', [FolderRule.keyPrefix + rule.folder, encodeSwiftJson(rule.toJson())]);

  /// Rules used to share one synced row. The first rule of each folder is the one kept.
  static void adoptLegacyFolderRules(SqlDatabase db) {
    final data = db.value<Uint8List>('SELECT value FROM library_order WHERE key = ?', [_legacyRulesKey]);
    if (data == null) return;
    final filled = fetchFolderRules(db).map((rule) => rule.folder).toSet();
    List<FolderRule> legacy;
    try {
      legacy = (jsonDecode(utf8.decode(data)) as List).map((value) => FolderRule.fromJson(jsonObject(value))).toList();
    } on Object {
      legacy = [];
    }
    for (final rule in legacy) {
      if (filled.add(rule.folder)) storeFolderRule(rule, db);
    }
    db.execute('DELETE FROM library_order WHERE key = ?', [_legacyRulesKey]);
  }

  void adoptLegacyRules() => dbWriter.write(adoptLegacyFolderRules);

  /// Rules whose folder was deleted, here or on another device, are skipped.
  static int? folderIDOfRule(FolderRule rule, SqlDatabase db) => db.value<int>('SELECT id FROM folders WHERE sync_id = ?', [rule.folder]);

  static String folderIdentity(int id, SqlDatabase db) {
    final identity = db.value<String>('SELECT sync_id FROM folders WHERE id = ?', [id]);
    if (identity != null) return identity;
    final name = db.value<String>('SELECT name FROM folders WHERE id = ?', [id]);
    final created = name == '미분류' ? 'unsorted' : uuidString();
    db.execute('UPDATE folders SET sync_id = ? WHERE id = ?', [created, id]);
    return created;
  }

  String identityOfFolder(int id) => dbWriter.write((db) => folderIdentity(id, db));

  List<({FolderRule rule, Folder folder})> folderRules() => dbWriter.read((db) {
    final folders = AppDatabase.fetchFolders(db);
    final rules = <({FolderRule rule, Folder folder})>[];
    for (final rule in fetchFolderRules(db)) {
      final id = folderIDOfRule(rule, db);
      final folder = folders.where((folder) => folder.id == id).firstOrNull;
      if (id != null && folder != null) rules.add((rule: rule, folder: folder));
    }
    rules.sort((a, b) {
      final order = a.folder.sortOrder.compareTo(b.folder.sortOrder);
      return order != 0 ? order : (a.folder.id ?? 0).compareTo(b.folder.id ?? 0);
    });
    return rules;
  });

  /// Unfiled and the default save folder: a work anywhere else was put there by someone.
  List<int> _landingFolderIDs(SqlDatabase db) {
    final ids = db.column<int>("SELECT id FROM folders WHERE name = '미분류'");
    final identity = LibrarySavePreferences.defaultFolderIdentity(db, preferences.defaults);
    final id = identity == null ? null : db.value<int>('SELECT id FROM folders WHERE sync_id = ?', [identity]);
    if (id != null) ids.add(id);
    return ids;
  }

  /// Which works a rule may take, over `works` aliased as `w`.
  String? _sourceCondition(FolderRule rule, SqlDatabase db) {
    if (rule.includesOtherFolders == true) return null;
    String list(List<int> ids) => ids.join(',');
    if (rule.sources == null) {
      return 'NOT EXISTS (SELECT 1 FROM folder_works fw WHERE fw.work_id = w.id AND fw.folder_id NOT IN (${list(_landingFolderIDs(db))}))';
    }
    return 'EXISTS (SELECT 1 FROM folder_works fw WHERE fw.work_id = w.id AND fw.folder_id IN (${list(_sourceFolderIDs(rule, db))}))';
  }

  /// The folders a rule looks in, never its own: where a moving rule takes works from.
  List<int> _sourceFolderIDs(FolderRule rule, SqlDatabase db) {
    final own = folderIDOfRule(rule, db);
    final List<int> ids;
    final sources = rule.sources;
    if (rule.includesOtherFolders == true) {
      ids = db.column<int>('SELECT id FROM folders');
    } else if (sources != null) {
      ids = sources.isEmpty ? [] : db.column<int>('SELECT id FROM folders WHERE sync_id IN (${List.filled(sources.length, '?').join(',')})', sources);
    } else {
      ids = _landingFolderIDs(db);
    }
    return ids.where((id) => id != own).toList();
  }

  (String, List<Object?>) _matching(FolderRule rule, SqlDatabase db) {
    final (conditions, arguments) = rule.workQuery.conditions;
    final source = _sourceCondition(rule, db);
    return (source == null ? conditions : '$conditions AND $source', arguments);
  }

  int matchingWorkCount(FolderRule rule) {
    if (rule.workQuery.isEmpty) return 0;
    return dbWriter.read((db) {
      final (conditions, arguments) = _matching(rule, db);
      return db.value<int>('SELECT COUNT(*) FROM works w WHERE $conditions', arguments) ?? 0;
    });
  }

  int matchingWorkCountElsewhere(FolderRule rule) {
    if (rule.workQuery.isEmpty || rule.includesOtherFolders == true) return 0;
    return dbWriter.read((db) {
      final (conditions, arguments) = rule.workQuery.conditions;
      final source = _sourceCondition(rule, db);
      if (source == null) return 0;
      final own = folderIDOfRule(rule, db) ?? -1;
      return db.value<int>(
            'SELECT COUNT(*) FROM works w WHERE $conditions AND NOT ($source) AND NOT EXISTS (SELECT 1 FROM folder_works fw WHERE fw.work_id = w.id AND fw.folder_id = ?)',
            [...arguments, own],
          ) ??
          0;
    });
  }

  /// Files saved works in a folder. A copying rule leaves them where they were too; a moving
  /// rule takes them out of the folders it looked in. Either way they leave Unfiled.
  void addMatchingWorks(FolderRule rule, int toFolder) {
    if (rule.workQuery.isEmpty) return;
    final now = iso8601();
    dbWriter.write((db) {
      final (conditions, arguments) = _matching(rule, db);
      final matched = db.column<int>('SELECT w.id FROM works w WHERE $conditions', arguments);
      for (final workID in matched) {
        db.execute('INSERT OR IGNORE INTO folder_works (folder_id, work_id, added_at) VALUES (?, ?, ?)', [toFolder, workID, now]);
      }
      if (!rule.copies) {
        final sources = _sourceFolderIDs(rule, db).where((id) => id != toFolder).toList();
        if (sources.isNotEmpty) {
          for (final workID in matched) {
            db.execute('DELETE FROM folder_works WHERE work_id = ? AND folder_id IN (${sources.join(',')})', [workID]);
          }
        }
      }
      _leaveUnfiledWhenIn(toFolder, db);
    });
  }

  static void _leaveUnfiledWhenIn(int folderID, SqlDatabase db) {
    final unfiled = db.value<int>("SELECT id FROM folders WHERE name = '미분류' ORDER BY sort_order ASC, id ASC LIMIT 1");
    if (unfiled == null || unfiled == folderID) return;
    db.execute('DELETE FROM folder_works WHERE folder_id = ? AND work_id IN (SELECT work_id FROM folder_works WHERE folder_id = ?)', [unfiled, folderID]);
  }

  /// Runs once for a new save and once when its tags first arrive, so a work a person
  /// moves stays where they put it, whether or not it fits the folder's tags.
  /// Every copying rule that matches adds the work; the first moving rule in folder order
  /// takes it out of where it was, and later moving rules leave it alone.
  void applyFolderRules(int toWork, String now, SqlDatabase db) {
    if (!LibrarySavePreferences.rulesEnabled(preferences.defaults)) return;
    final order = db.column<String>('SELECT sync_id FROM folders WHERE sync_id IS NOT NULL ORDER BY sort_order, id');
    int position(FolderRule rule) {
      final index = order.indexOf(rule.folder);
      return index < 0 ? order.length : index;
    }

    // Read once, or the first match would hide the work from every later rule.
    final rules = fetchFolderRules(db).where((rule) {
      if (!rule.isActive || rule.workQuery.isEmpty) return false;
      final source = _sourceCondition(rule, db);
      if (source == null) return true;
      return db.exists('SELECT EXISTS(SELECT 1 FROM works w WHERE w.id = ? AND $source)', [toWork]);
    }).toList()..sort((a, b) => position(a).compareTo(position(b)));
    final before = db.column<int>('SELECT folder_id FROM folder_works WHERE work_id = ?', [toWork]).toSet();
    var moved = false;
    for (final rule in rules) {
      if (!rule.copies && moved) continue;
      final folderID = folderIDOfRule(rule, db);
      if (folderID == null) continue;
      final (conditions, arguments) = rule.workQuery.conditions;
      if (!db.exists('SELECT EXISTS(SELECT 1 FROM works w WHERE w.id = ? AND $conditions)', [toWork, ...arguments])) continue;
      db.execute('INSERT OR IGNORE INTO folder_works (folder_id, work_id, added_at) VALUES (?, ?, ?)', [folderID, toWork, now]);
      if (!rule.copies) {
        moved = true;
        // Only folders it was in before, so a copy another smart folder just made stays.
        for (final source in _sourceFolderIDs(rule, db)) {
          if (source != folderID && before.contains(source)) db.execute('DELETE FROM folder_works WHERE folder_id = ? AND work_id = ?', [source, toWork]);
        }
      }
      final unfiled = db.value<int>("SELECT id FROM folders WHERE name = '미분류' ORDER BY sort_order ASC, id ASC LIMIT 1");
      if (unfiled == null || unfiled == folderID) continue;
      db.execute('DELETE FROM folder_works WHERE folder_id = ? AND work_id = ?', [unfiled, toWork]);
    }
  }

  List<int> folderIDs(int galleryId) => dbWriter.read(
    (db) =>
        db.column<int>('SELECT fw.folder_id FROM folder_works fw JOIN works w ON w.id = fw.work_id WHERE w.gallery_id = ? ORDER BY fw.added_at', [galleryId]),
  );

  /// Holds and quick saves land here; a folder deleted since falls back to Unfiled.
  Folder defaultSaveFolder() {
    final folders = listFolders();
    final chosen = dbWriter.read((db) {
      final identity = LibrarySavePreferences.defaultFolderIdentity(db, preferences.defaults);
      return identity == null ? null : db.value<int>('SELECT id FROM folders WHERE sync_id = ?', [identity]);
    });
    return folders.where((folder) => folder.id == chosen).firstOrNull ??
        folders.where((folder) => folder.name == '미분류').firstOrNull ??
        folders.firstOrNull ??
        ensureDefaultFolder();
  }

  /// Adding a work to a real folder takes it out of Unfiled.
  void addWork(int galleryId, int folderID) {
    final now = iso8601();
    dbWriter.write((db) {
      final workID = db.value<int>('SELECT id FROM works WHERE gallery_id = ?', [galleryId]);
      if (workID == null) return;
      db.execute('INSERT OR IGNORE INTO folder_works (folder_id, work_id, added_at) VALUES (?, ?, ?)', [folderID, workID, now]);
      _leaveUnfiledWhenIn(folderID, db);
    });
  }

  /// For merges, which can bring a work's Unfiled membership along with real folders.
  static void leaveUnfiled(int workID, SqlDatabase db) => db.execute(
    '''
    DELETE FROM folder_works
    WHERE work_id = ? AND folder_id IN (SELECT id FROM folders WHERE name = '미분류')
      AND EXISTS (SELECT 1 FROM folder_works fw JOIN folders f ON f.id = fw.folder_id WHERE fw.work_id = ? AND f.name != '미분류')
    ''',
    [workID, workID],
  );

  // SmartFolderLibrary

  List<SmartFolderChoice> ruleFolderChoices() => dbWriter.write(
    (db) => [
      for (final folder in AppDatabase.fetchFolders(db))
        if (folder.id != null) SmartFolderChoice(id: folderIdentity(folder.id!, db), name: folder.displayName, canBeSmart: folder.name != '미분류'),
    ],
  );

  Set<String> ruleDefaultSources() => dbWriter.write((db) => {for (final id in _landingFolderIDs(db)) folderIdentity(id, db)});

  FolderRule? ruleForFolder(String id) => dbWriter.read((db) => fetchFolderRules(db).where((rule) => rule.folder == id).firstOrNull);

  String createRuleFolderNamed(String name) {
    final id = createFolder(name: name).id;
    if (id == null) throw const BooruError(BooruErrorKind.storage);
    return identityOfFolder(id);
  }

  void saveFolderRule(FolderRule rule) => dbWriter.write((db) => storeFolderRule(rule, db));

  void deleteFolderRule(String id) => dbWriter.write((db) => db.execute('DELETE FROM library_order WHERE key = ?', [FolderRule.keyPrefix + id]));

  void fillRule(FolderRule rule) {
    final id = dbWriter.read((db) => folderIDOfRule(rule, db));
    if (id != null) addMatchingWorks(rule, id);
  }
}

extension BooruStoreFolderRules on BooruStore {
  static List<FolderRule> fetchFolderRules(SqlDatabase db) => db
      .column<String>('SELECT value FROM settings WHERE key GLOB ?', ['${FolderRule.keyPrefix}*'])
      .map((value) => FolderRule.tryDecode(utf8.encode(value)))
      .nonNulls
      .toList();

  static void storeFolderRule(FolderRule rule, SqlDatabase db) =>
      db.execute('INSERT OR REPLACE INTO settings VALUES (?, ?)', [FolderRule.keyPrefix + rule.folder, encodeSwiftJsonString(rule.toJson())]);

  /// New favorites land in their site's folder, or Uncategorized.
  static bool isLanding(String folder) => folder == 'unsorted' || folder.startsWith('site:');

  static bool _reads(FolderRule rule, String folder) {
    if (folder == rule.folder) return false;
    if (rule.includesOtherFolders == true) return true;
    return rule.sources?.contains(folder) ?? isLanding(folder);
  }

  /// An image is in one folder, so the first matching smart folder takes it. Only new
  /// favorites come through here, so an image a person moves stays where they put it.
  static String smartDestination(BooruPost post, String landing, SqlDatabase db, Preferences defaults) {
    if (!LibrarySavePreferences.rulesEnabled(defaults)) return landing;
    final rules = fetchFolderRules(db).where((rule) => rule.isActive && _reads(rule, landing)).toList();
    if (rules.isEmpty) return landing;
    for (final id in db.column<String>('SELECT id FROM folders ORDER BY position, name')) {
      final match = rules.where((rule) => rule.folder == id).firstOrNull;
      if (match != null && match.postMatcher(post)) return id;
    }
    return landing;
  }

  List<BooruPost> _matches(FolderRule rule) {
    final matcher = rule.postMatcher;
    return [
      for (final record in favoriteRecords())
        if (_reads(rule, record.folderID) && matcher(record.post)) record.post,
    ];
  }

  List<SmartFolderChoice> ruleFolderChoices() => [
    for (final folder in folders()) SmartFolderChoice(id: folder.id, name: folder.displayName, canBeSmart: folder.id != 'unsorted'),
  ];

  Set<String> ruleDefaultSources() => folders().map((folder) => folder.id).where(isLanding).toSet();

  FolderRule? ruleForFolder(String id) => database.read((db) => fetchFolderRules(db).where((rule) => rule.folder == id).firstOrNull);

  List<FolderRule> ruleList() {
    final rules = database.read(fetchFolderRules);
    return [for (final folder in folders()) ?rules.where((rule) => rule.folder == folder.id).firstOrNull];
  }

  int matchingRuleCount(FolderRule rule) => _matches(rule).length;

  int matchingRuleCountElsewhere(FolderRule rule) {
    final matcher = rule.postMatcher;
    return favoriteRecords().where((record) => record.folderID != rule.folder && !_reads(rule, record.folderID) && matcher(record.post)).length;
  }

  void saveFolderRule(FolderRule rule) => setSetting(FolderRule.keyPrefix + rule.folder, encodeSwiftJsonString(rule.toJson()));

  void deleteFolderRule(String id) => removeSetting(FolderRule.keyPrefix + id);

  void fillRule(FolderRule rule) => moveFavorites(_matches(rule), rule.folder);
}
