import 'dart:typed_data';

import '../support/swift_json.dart';
import 'taste_models.dart';
import 'taste_recap.dart';
import 'taste_store.dart';

/// Pure, deterministic statistics. No language model sees tags or computes numbers.
abstract final class TasteAnalyzer {
  static const version = 6;

  /// Events by ID, the latest copy of each, in time order.
  static List<TasteEvent> deduplicated(List<TasteEvent> input, TasteControl control) {
    final byID = <String, TasteEvent>{};
    for (final event in input) {
      if (event.epoch != control.epoch) continue;
      final existing = byID[event.id];
      byID[event.id] = existing == null || TasteEvent.ordered(existing, event) ? event : existing;
    }
    return byID.values.toList()..sort(TasteEvent.compare);
  }

  static TasteSnapshot analyze(
    List<TasteEvent> input, {
    required TasteControl control,
    TasteInterval? period,
    TasteInterval? previous,
    Set<String>? savedKeys,
    TasteMode mode = TasteMode.booru,
  }) {
    final events = deduplicated(input, control);
    final metadataBySource = <String, Set<String>>{};
    for (final event in events) {
      metadataBySource.putIfAbsent(event.item.source, () => {}).addAll(event.item.metadata.map(TasteTagPolicy.normalize));
    }
    List<String> eligibleTags(TasteItem item) => TasteTagPolicy.filter(
      item.tags,
      metadata: (metadataBySource[item.source] ?? const <String>{}).toList(),
    ).where((tag) => control.allows(tag, source: item.source, mode: mode)).toList();

    var active = <String, TasteEvent>{};
    final latestMetadata = <String, TasteItem>{};
    final searched = <String>{};
    final observed = <String, TasteItem>{};
    final chosen = <String, TasteEvent>{};
    final searches = <String, int>{};
    final activity = <DateTime, int>{};
    final previousWorks = <String>{};
    final previousTags = <String, Set<String>>{};
    var searchCount = 0;
    final searchSessions = <String>{};
    final calendar = TasteCalendar(control.timeZone);
    bool within(TasteEvent event) => period?.contains(event.at) ?? true;
    for (final event in events) {
      final item = event.item;
      final eligible = eligibleTags(item);
      if (event.kind == TasteEventKind.search && event.context.origin == DiscoveryOrigin.search) {
        for (final tag in eligible) {
          searched.add(TasteControl.tagKey(source: item.source, tag: tag));
        }
        if (within(event)) {
          if (searchSessions.add(event.context.session)) searchCount += 1;
          for (final tag in eligible) {
            final key = TasteControl.tagKey(source: item.source, tag: tag);
            searches[key] = (searches[key] ?? 0) + 1;
          }
        }
      }
      if (event.kind == TasteEventKind.metadata) latestMetadata[item.key] = item;
      if (const {TasteEventKind.save, TasteEventKind.seed, TasteEventKind.imported}.contains(event.kind)) {
        active[item.key] = event;
        latestMetadata.remove(item.key);
      }
      if (event.kind == TasteEventKind.remove) active.remove(item.key);
      if (event.kind == TasteEventKind.save && event.context.organic) {
        for (final tag in eligible) {
          if (event.context.included.contains(tag)) searched.add(TasteControl.tagKey(source: item.source, tag: tag));
        }
      }
      if (within(event)) {
        if ((event.kind == TasteEventKind.open || event.kind == TasteEventKind.save) && event.context.organic) observed[item.key] = item;
        if (event.kind == TasteEventKind.save && chosen[item.key] == null) {
          chosen[item.key] = event;
          final day = calendar.startOfDay(calendar.fromSeconds(event.at));
          activity[day] = (activity[day] ?? 0) + 1;
        }
      }
      if (previous != null && event.kind == TasteEventKind.save && previous.contains(event.at)) {
        previousWorks.add(item.key);
        for (final tag in eligible) {
          previousTags.putIfAbsent(TasteControl.tagKey(source: item.source, tag: tag), () => {}).add(item.key);
        }
      }
    }
    if (period == null && savedKeys != null) {
      active = {
        for (final entry in active.entries)
          if (savedKeys.contains(entry.key)) entry.key: entry.value,
      };
    }
    // Historical periods describe activity then. The live profile describes current saved items.
    final evidence = <String, TasteEvent>{};
    for (final entry in (period == null ? active : chosen).entries) {
      final metadata = latestMetadata[entry.key];
      evidence[entry.key] = metadata == null ? entry.value : (TasteEvent.fromJson(entry.value.toJson())..item = metadata);
    }
    for (final entry in latestMetadata.entries) {
      if (observed.containsKey(entry.key)) observed[entry.key] = entry.value;
    }
    final tags = <String, TasteTag>{};
    final savedPerSource = <String, int>{};
    final organicSavedTags = <String, int>{};
    final openedPerSource = <String, int>{};
    bool allowed(String name, String source) => !control.excluded.contains(TasteControl.tagKey(source: source, tag: name));
    for (final item in observed.values) {
      openedPerSource[item.source] = (openedPerSource[item.source] ?? 0) + 1;
      for (final name in eligibleTags(item)) {
        if (!allowed(name, item.source)) continue;
        final key = TasteControl.tagKey(source: item.source, tag: name);
        (tags[key] ??= TasteTag(source: item.source, name: name)).opened += 1;
      }
    }
    for (final event in evidence.values) {
      final item = event.item;
      if (event.context.organic) savedPerSource[item.source] = (savedPerSource[item.source] ?? 0) + 1;
      for (final name in eligibleTags(item)) {
        if (!allowed(name, item.source) || (event.context.constraints.contains(name) && !event.context.included.contains(name))) continue;
        final key = TasteControl.tagKey(source: item.source, tag: name);
        final tag = tags[key] ??= TasteTag(source: item.source, name: name);
        if (event.context.preferenceAction) {
          if (event.context.organic) organicSavedTags[key] = (organicSavedTags[key] ?? 0) + 1;
          if (event.context.chosenTags.contains(name)) {
            tag.confirmed += 1;
          } else {
            tag.hidden += 1;
            tag.sessions.add(event.context.session);
          }
        } else {
          tag.general += 1;
        }
        tag.works.add(item);
      }
    }
    for (final entry in searches.entries) {
      final split = entry.key.indexOf('\n');
      if (control.excluded.contains(entry.key) || split < 0) continue;
      (tags[entry.key] ??= TasteTag(source: entry.key.substring(0, split), name: entry.key.substring(split + 1))).searches = entry.value;
    }
    for (final MapEntry(:key, value: tag) in tags.entries) {
      tag.previouslySearched = searched.contains(key) || tag.confirmed > 0;
      final opened = openedPerSource[tag.source] ?? 0, saved = savedPerSource[tag.source] ?? 0;
      if (opened >= 30 && saved >= 10) {
        final selectedRate = ((organicSavedTags[key] ?? 0) + 1) / (saved + 2);
        final baselineRate = (tag.opened + 1) / (opened + 2);
        tag.lift = selectedRate / baselineRate;
      }
      tag.works.sort((a, b) => a.key.compareTo(b.key));
    }
    final digestData = encodeJson([for (final event in events) event.toJson()]);
    final controlData = control.analysisKey(mode).codeUnits;
    String seconds(TasteInterval? interval, bool start) => interval == null ? '-1' : '${start ? interval.startSeconds : interval.endSeconds}';
    final signature = [
      ...'$version:${TasteTagPolicy.version}:${control.timeZone}:${seconds(period, true)}:${seconds(period, false)}:${seconds(previous, true)}:${seconds(previous, false)}'
          .codeUnits,
      ...encodeJson(evidence.keys.toList()..sort()),
    ];
    final result = tags.values.where((tag) => tag.count > 0 || tag.searches > 0).toList()
      ..sort((a, b) => a.weight == b.weight ? a.id.compareTo(b.id) : b.weight.compareTo(a.weight));
    return TasteSnapshot(
      tags: result,
      saves: chosen.length,
      opens: observed.length,
      searches: searchCount,
      activity: activity,
      digest: tasteDigest([...digestData, ...controlData, ...signature]),
      period: period,
      previousSaves: previous == null ? null : previousWorks.length,
      previousTagCounts: previousTags.map((key, value) => MapEntry(key, value.length)),
    );
  }
}

/// Decoded history and recent snapshots per mode. Only a committed write to the
/// analysis store's database reloads its events; up to six snapshots stay cached.
class TasteAnalysisCache {
  final _entries = <TasteMode, _CacheEntry>{};
  int analysisCount = 0;
  int eventLoadCount = 0;

  _CacheEntry _refreshed(TasteStore store, TasteControl control) {
    final entry = _entries[store.mode] ??= _CacheEntry();
    final revision = store.database.revision;
    if (!identical(entry.database, store.database) || entry.revision != revision || entry.epoch != control.epoch || entry.events == null) {
      final events = store.allEvents();
      eventLoadCount += 1;
      if (!identical(entry.database, store.database) || entry.epoch != control.epoch || !_sameEvents(entry.events, events)) entry.snapshots.clear();
      entry
        ..database = store.database
        ..revision = revision
        ..epoch = control.epoch
        ..events = events;
    }
    return entry;
  }

  static bool _sameEvents(List<TasteEvent>? a, List<TasteEvent> b) {
    if (a == null || a.length != b.length) return false;
    for (var index = 0; index < a.length; index++) {
      if (a[index].id != b[index].id || a[index].at != b[index].at || a[index].item != b[index].item) return false;
    }
    return true;
  }

  RecapIndex recapIndex(TasteStore store, TasteControl control, Map<String, RecapWorkInfo> library) =>
      RecapIndex(events: _refreshed(store, control).events!, control: control, mode: store.mode, library: library);

  TasteSnapshot snapshot(TasteStore store, TasteControl control, {TasteInterval? period, TasteInterval? previous, Set<String>? savedKeys}) {
    final entry = _refreshed(store, control);
    final keys = period == null ? savedKeys : null;
    final key = [control.analysisKey(store.mode), period, previous, keys == null ? null : (keys.toList()..sort()).join('\n')].join('|');
    final index = entry.snapshots.indexWhere((cached) => cached.$1 == key);
    if (index >= 0) {
      final cached = entry.snapshots.removeAt(index);
      entry.snapshots.add(cached);
      return cached.$2;
    }
    final result = TasteAnalyzer.analyze(entry.events!, control: control, period: period, previous: previous, savedKeys: savedKeys, mode: store.mode);
    analysisCount += 1;
    entry.snapshots.add((key, result));
    // Historical reports contain per-tag work lists; bound retained history.
    if (entry.snapshots.length > 6) entry.snapshots.removeAt(0);
    return result;
  }

  void invalidate() => _entries.clear();
}

class _CacheEntry {
  Object? database;
  int revision = -1;
  String epoch = '';
  List<TasteEvent>? events;
  final snapshots = <(String, TasteSnapshot)>[];
}

enum TasteInsightPattern { confirmed, discovery, frequent, rising, association }

class TasteInsight {
  TasteInsight({required this.tagKey, this.relatedKey, required this.pattern});
  String tagKey;
  String? relatedKey;
  TasteInsightPattern pattern;
  String get id => '$tagKey:${pattern.name}';

  factory TasteInsight.fromJson(JsonObject json) => TasteInsight(
    tagKey: json.string('tagKey'),
    relatedKey: json.stringOrNull('relatedKey'),
    pattern: TasteInsightPattern.values.byName(json.string('pattern')),
  );
  JsonObject toJson() => <String, Object?>{'tagKey': tagKey, 'pattern': pattern.name}..putIfPresent('relatedKey', relatedKey);

  @override
  bool operator ==(Object other) => other is TasteInsight && other.tagKey == tagKey && other.relatedKey == relatedKey && other.pattern == pattern;
  @override
  int get hashCode => Object.hash(tagKey, relatedKey, pattern);
}

class TasteReport {
  TasteReport({this.version = 2, required this.epoch, required this.digest, required this.language, required this.insights});
  int version;
  String epoch;
  String digest;
  String language;
  List<TasteInsight> insights;

  String get id => tasteDigestOf(epoch + digest + language);

  bool isValid(TasteSnapshot snapshot) {
    if (version != 2 || digest != snapshot.digest || insights.length > 3 || insights.map((insight) => insight.tagKey).toSet().length != insights.length) {
      return false;
    }
    return insights.every((insight) {
      final tag = snapshot.tags.where((tag) => tag.id == insight.tagKey).firstOrNull;
      if (tag == null || tag.count <= 0) return false;
      if (insight.pattern != TasteInsightPattern.association && insight.relatedKey != null) return false;
      switch (insight.pattern) {
        case TasteInsightPattern.frequent:
          return true;
        case TasteInsightPattern.confirmed:
          return tag.confirmed > 0;
        case TasteInsightPattern.discovery:
          return tag.discovery;
        case TasteInsightPattern.rising:
          return snapshot.previousSaves != null && tag.count > (snapshot.previousTagCounts[tag.id] ?? 0);
        case TasteInsightPattern.association:
          final related = snapshot.tags.where((other) => other.id == insight.relatedKey).firstOrNull;
          if (related == null || related.id == tag.id || related.source != tag.source) return false;
          final works = tag.works.map((item) => item.key).toSet(), theirs = related.works.map((item) => item.key).toSet();
          final overlap = works.intersection(theirs).length;
          return overlap >= 5 && overlap / (works.length > theirs.length ? works.length : theirs.length) >= 0.8;
      }
    });
  }

  factory TasteReport.fromJson(JsonObject json) => TasteReport(
    version: json.integer('version'),
    epoch: json.string('epoch'),
    digest: json.string('digest'),
    language: json.string('language'),
    insights: json.list('insights', (value) => TasteInsight.fromJson(jsonObject(value))),
  );

  // Wire-only retirement flag keeps older app versions able to decode reports.
  JsonObject toJson() => {
    'generatedByAI': false,
    'version': version,
    'epoch': epoch,
    'digest': digest,
    'language': language,
    'insights': [for (final insight in insights) insight.toJson()],
  };

  @override
  bool operator ==(Object other) => other is TasteReport && encodeJsonString(other.toJson()) == encodeJsonString(toJson());
  @override
  int get hashCode => encodeJsonString(toJson()).hashCode;
}

abstract final class StatisticalInsightService {
  static TasteReport report({required TasteSnapshot snapshot, required TasteControl control, required String language, int selectionOffset = 0}) {
    final eligible = snapshot.tags.where((tag) => tag.count > 0).take(24).toList();
    final rotated = eligible.isEmpty
        ? <TasteTag>[]
        : [for (var index = 0; index < eligible.length; index++) eligible[((selectionOffset < 0 ? 0 : selectionOffset) + index) % eligible.length]];
    final insights = rotated.where((tag) => tag.discovery).take(1).map((tag) => TasteInsight(tagKey: tag.id, pattern: TasteInsightPattern.discovery)).toList();
    for (final tag in rotated) {
      if (insights.any((insight) => insight.tagKey == tag.id)) continue;
      if (insights.length == 3) break;
      final rising = snapshot.previousSaves != null && tag.count >= 3 && tag.count > (snapshot.previousTagCounts[tag.id] ?? 0);
      insights.add(
        TasteInsight(
          tagKey: tag.id,
          pattern: rising
              ? TasteInsightPattern.rising
              : tag.confirmed > 0
              ? TasteInsightPattern.confirmed
              : TasteInsightPattern.frequent,
        ),
      );
    }
    return TasteReport(epoch: control.epoch, digest: snapshot.digest, language: language, insights: insights);
  }
}

extension TasteStoreReports on TasteStore {
  TasteReport? report({required String digest, required String language, required String epoch}) {
    final data = database.read((db) => db.value<Uint8List>('SELECT payload FROM taste_reports WHERE id = ?', [tasteDigestOf(epoch + digest + language)]));
    return data == null ? null : TasteReport.fromJson(decodeJsonObject(data));
  }

  void saveReport(TasteReport report, {bool uploaded = false}) => database.write((db) {
    if (TasteStore.control(db).epoch != report.epoch) return;
    final data = db.value<Uint8List>('SELECT payload FROM taste_reports WHERE id = ?', [report.id]);
    if (data != null) {
      try {
        if (TasteReport.fromJson(decodeJsonObject(data)) == report) return;
      } on SwiftJsonError {
        // Replace an unreadable report.
      }
    }
    db.execute('INSERT OR REPLACE INTO taste_reports VALUES (?, ?, ?)', [report.id, encodeSwiftJson(report.toJson()), uploaded]);
  });

  List<TasteReport> pendingReports() => database.read(
    (db) => db
        .column<Uint8List>('SELECT payload FROM taste_reports WHERE uploaded = 0 LIMIT 20')
        .map((data) => TasteReport.fromJson(decodeJsonObject(data)))
        .toList(),
  );

  void acknowledgeReports(List<String> ids) => database.write((db) {
    for (final id in ids) {
      db.execute('UPDATE taste_reports SET uploaded = 1 WHERE id = ?', [id]);
    }
  });
}
