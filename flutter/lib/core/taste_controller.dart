import 'dart:convert';

import '../data/library_store.dart';
import 'content.dart';
import 'insights.dart';
import 'library.dart';

/// Local event evidence, separate from saved works and portable backups.
class LocalTasteController {
  LocalTasteController(this.store) {
    store.database.execute('''
      CREATE TABLE IF NOT EXISTS taste_events_local (
        id INTEGER PRIMARY KEY AUTOINCREMENT,
        kind TEXT NOT NULL, item_key TEXT NOT NULL, mode TEXT NOT NULL,
        at TEXT NOT NULL, payload TEXT NOT NULL
      )
    ''');
    store.database.execute(
      'CREATE INDEX IF NOT EXISTS taste_events_local_mode ON taste_events_local(mode, id)',
    );
    store.database.execute(
      'CREATE INDEX IF NOT EXISTS taste_events_local_period ON taste_events_local(mode, at, kind)',
    );
  }
  final LibraryStore store;
  static const _key = 'taste.localEvidence';

  bool get enabled => store.setting('taste.enabled', true) == true;
  void setEnabled(bool value) => store.setSetting('taste.enabled', value);

  bool get initialized => store.portable(_key)?['initialized'] == true;

  /// Seeds the existing library once. Reset preserves the initialization marker.
  void seed(Iterable<SavedItem> saved) {
    if (initialized) return;
    store.transaction(() {
      if (enabled) {
        for (final item in saved) {
          _insert('seed', item.item, item.savedAt);
        }
      }
      store.setPortable(_key, {'initialized': true});
    });
  }

  void record(String kind, ContentItem item, {DateTime? at}) {
    if (!enabled || !{'save', 'remove', 'open', 'imported'}.contains(kind)) {
      return;
    }
    store.transaction(() {
      _insert(kind, item, at ?? DateTime.now());
      store.setPortable(_key, {'initialized': true});
    });
  }

  void _insert(String kind, ContentItem item, DateTime at) =>
      store.database.execute(
        'INSERT INTO taste_events_local(kind,item_key,mode,at,payload) VALUES (?,?,?,?,?)',
        [
          kind,
          item.key,
          item.mode.name,
          at.toUtc().toIso8601String(),
          jsonEncode(item.toJson()),
        ],
      );

  void reset() => store.transaction(() {
    store.database.execute('DELETE FROM taste_events_local');
    store.setPortable(_key, {'initialized': true});
  });

  /// Replays saved/removed events; paused analysis keeps its existing state.
  List<SavedItem> analysisItems(AppMode mode) {
    final active = <String, SavedItem>{};
    for (final row in _rows(mode)) {
      final key = row['item_key'] as String;
      if (row['kind'] == 'remove') {
        active.remove(key);
        continue;
      }
      if (row['kind'] != 'seed' &&
          row['kind'] != 'save' &&
          row['kind'] != 'imported') {
        continue;
      }
      final item = _item(row['payload']);
      final at = DateTime.tryParse(row['at'] as String);
      if (item != null && at != null) {
        active[key] = SavedItem(item: item, savedAt: at);
      }
    }
    return active.values.toList();
  }

  /// Organic saves and opens form the observed population used for lift.
  List<ContentItem> observedItems(AppMode mode) {
    final observed = <String, ContentItem>{};
    for (final row in _rows(mode)) {
      if (row['kind'] != 'open' && row['kind'] != 'save') continue;
      final item = _item(row['payload']);
      if (item != null) observed[item.key] = item;
    }
    return observed.values.toList();
  }

  List<ContentItem> organicSavedItems(AppMode mode) {
    final active = <String, ContentItem>{};
    for (final row in _rows(mode)) {
      final key = row['item_key'] as String;
      if (row['kind'] == 'remove' ||
          row['kind'] == 'seed' ||
          row['kind'] == 'imported') {
        active.remove(key);
        continue;
      }
      if (row['kind'] != 'save') continue;
      final item = _item(row['payload']);
      if (item != null) active[key] = item;
    }
    return active.values.toList();
  }

  /// Save/open events in the requested period remain visible after unsaving.
  List<SavedItem> historySaves(AppMode mode, {required DateTime since}) =>
      _history(mode, since, const ['save']);
  List<SavedItem> historyOpens(AppMode mode, {required DateTime since}) =>
      _history(mode, since, const ['open', 'save']);

  List<SavedItem> _history(AppMode mode, DateTime since, List<String> kinds) {
    final rows = store.database.select(
      "SELECT at,payload FROM taste_events_local WHERE mode=? AND at>=? AND kind IN (${List.filled(kinds.length, '?').join(',')}) ORDER BY at,id",
      [mode.name, since.toUtc().toIso8601String(), ...kinds],
    );
    final result = <SavedItem>[];
    for (final row in rows) {
      final item = _item(row['payload']);
      final at = DateTime.tryParse(row['at'] as String);
      if (item != null && at != null) {
        result.add(SavedItem(item: item, savedAt: at));
      }
    }
    return result;
  }

  dynamic _rows(AppMode mode) => store.database.select(
    'SELECT kind,item_key,at,payload FROM taste_events_local WHERE mode=? ORDER BY id',
    [mode.name],
  );
  static ContentItem? _item(dynamic payload) {
    try {
      return ContentItem.fromJson(
        Map<String, dynamic>.from(jsonDecode(payload as String) as Map),
      );
    } on FormatException {
      return null;
    } on TypeError {
      return null;
    } on ArgumentError {
      return null;
    }
  }

  InsightPreferences preferences(AppMode mode) {
    final exclusions = store.setting('insights.exclusions.${mode.name}');
    final bySource = store.setting(
      'insights.exclusionsBySource.${mode.name}',
      <String, dynamic>{},
    );
    final rejected = store.setting(
      'recommendation.excludedTags',
      <String, dynamic>{},
    );
    final included = store.setting(
      'recommendation.includedTags',
      <String, dynamic>{},
    );
    return InsightPreferences(
      mode: mode,
      excludedTags: exclusions is List
          ? exclusions.whereType<String>().toSet()
          : null,
      excludedBySource: _tagMap(bySource),
      includedBySource: _tagMap(included),
      excludedRecommendationBySource: _tagMap(rejected),
    );
  }

  static Map<String, Set<String>> _tagMap(dynamic value) => value is Map
      ? {
          for (final entry in value.entries)
            if (entry.key is String && entry.value is List)
              entry.key as String: (entry.value as List)
                  .whereType<String>()
                  .map(InsightPreferences.normalize)
                  .where((tag) => tag.isNotEmpty)
                  .toSet(),
        }
      : {};
}
