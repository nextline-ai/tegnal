import 'dart:convert';
import 'dart:math' as math;

import 'package:collection/collection.dart';
import 'package:crypto/crypto.dart';

import '../booru/booru_models.dart';
import '../content/gallery_content.dart';
import '../support/l10n.dart';
import '../support/swift_json.dart';

enum DiscoveryOrigin { search, feed, recommendation, library, external }

class DiscoveryContext {
  DiscoveryContext({DiscoveryOrigin origin = DiscoveryOrigin.external, String query = '', String defaults = '', String? session})
    : this._(origin, session ?? uuidString(), splitWhitespace(query).where((term) => !term.startsWith('-')).map(TasteTagPolicy.normalize).toSet(), {
        ...splitWhitespace(defaults).map((term) => TasteTagPolicy.normalize(term.replaceAll(RegExp(r'^-+|-+$'), ''))),
        ...splitWhitespace(query).where((term) => term.startsWith('-')).map((term) => TasteTagPolicy.normalize(term.substring(1))),
      }, null);

  DiscoveryContext._(this.origin, this.session, this.included, this.constraints, this.recommendationTags);

  DiscoveryOrigin origin;
  String session;
  Set<String> included;
  Set<String> constraints;
  Set<String>? recommendationTags;

  static final unknown = DiscoveryContext(origin: DiscoveryOrigin.external, session: 'unknown');

  static DiscoveryContext recommended(String tag, {required String session}) =>
      DiscoveryContext(origin: DiscoveryOrigin.recommendation, session: session)..recommendationTags = {TasteTagPolicy.normalize(tag)};

  // A deliberate save from recommendations is evidence, but never a search.
  bool get preferenceAction => organic || (origin == DiscoveryOrigin.recommendation && recommendationTags != null);
  Set<String> get chosenTags =>
      (origin == DiscoveryOrigin.recommendation ? recommendationTags ?? const <String>{} : included).map(TasteTagPolicy.normalize).toSet();
  bool get organic => origin == DiscoveryOrigin.search || origin == DiscoveryOrigin.feed;

  factory DiscoveryContext.fromJson(JsonObject json) => DiscoveryContext._(
    DiscoveryOrigin.values.byName(json.string('origin')),
    json.string('session'),
    json.strings('included').toSet(),
    json.strings('constraints').toSet(),
    json.stringsOrNull('recommendationTags')?.toSet(),
  );

  JsonObject toJson() =>
      <String, Object?>{'origin': origin.name, 'session': session, 'included': included.toList()..sort(), 'constraints': constraints.toList()..sort()}
        ..putIfPresent('recommendationTags', recommendationTags == null ? null : (recommendationTags!.toList()..sort()));
}

abstract final class TasteTagPolicy {
  static const version = 2;

  // Exact matches only. Unknown and artistic categories remain eligible.
  static const technical = {
    'jpg', 'jpeg', 'png', 'gif', 'webp', 'avif', 'apng', 'bmp', 'tiff', 'svg', 'mp4', 'webm', 'mov', 'flash', 'video', //
    'animated', 'animated_gif', 'animated_png', 'sound', 'audio', 'no_sound', 'highres', 'absurdres', //
    'incredibly_absurdres', 'lowres', 'huge_filesize', 'big_filesize', 'small_filesize', 'wide_image', 'tall_image', //
    'jpeg_artifacts', 'compression_artifacts', 'tagme', 'translation_request', 'translated', 'partially_translated', //
    'check_translation', 'commentary_request', 'commentary', 'translated_commentary', 'source_request', 'bad_id', //
    'bad_link', 'bad_pixiv_id', 'bad_twitter_id', 'duplicate', 'revision', 'resized', 'upscaled', 'md5_mismatch', //
    'corrupted_file',
  };
  static const operators = {
    'rating', 'order', 'sort', 'score', 'id', 'width', 'height', 'mpixels', 'filesize', 'filetype', 'status', 'date', //
    'age', 'pool', 'limit', 'page', 'language', 'type',
  };

  static String normalize(String tag) => tag.trim().toLowerCase().replaceAll(' ', '_');

  static bool eligible(String tag, {Set<String> metadata = const {}}) {
    final value = normalize(tag);
    if (value.isEmpty || technical.contains(value) || metadata.contains(value) || value.startsWith('-')) return false;
    final colon = value.indexOf(':');
    if (colon >= 0 && operators.contains(value.substring(0, colon))) return false;
    return !value.contains('*') && !value.contains('~') && !value.contains('{') && !value.contains('}');
  }

  static List<String> filter(List<String> tags, {List<String> metadata = const []}) {
    final blocked = metadata.map(normalize).toSet();
    return tags.map(normalize).where((tag) => eligible(tag, metadata: blocked)).toSet().toList()..sort();
  }
}

enum TasteMode { booru, comics }

class TasteItem {
  TasteItem({required this.source, required this.id, required this.tags, this.metadata = const []});

  final String source;
  final int id;
  final List<String> tags;
  final List<String> metadata;

  String get key => '$source#$id';
  List<String> get eligibleTags => TasteTagPolicy.filter(tags, metadata: metadata);

  /// `source` is the comics site address (`MangaUrls.source`).
  static TasteItem comic(int id, {String? tags, required String source}) =>
      TasteItem(source: source, id: id, tags: (tags ?? '').split(',').map((tag) => tag.trim()).toList());

  factory TasteItem.fromJson(JsonObject json) =>
      TasteItem(source: json.string('source'), id: json.integer('id'), tags: json.strings('tags'), metadata: json.strings('metadata'));

  JsonObject toJson() => {'source': source, 'id': id, 'tags': tags, 'metadata': metadata};

  static const _lists = ListEquality<String>();
  @override
  bool operator ==(Object other) =>
      other is TasteItem && other.source == source && other.id == id && _lists.equals(other.tags, tags) && _lists.equals(other.metadata, metadata);
  @override
  int get hashCode => Object.hash(source, id, _lists.hash(tags), _lists.hash(metadata));
}

/// Foreground time on one work. Old peers ignore it and still decode the event.
class TasteDwell {
  const TasteDwell({required this.seconds, this.pages = 1, this.finished = false});
  final double seconds;
  final int pages;
  final bool finished;

  factory TasteDwell.fromJson(JsonObject json) => TasteDwell(seconds: json.number('seconds'), pages: json.integer('pages'), finished: json.boolean('finished'));
  JsonObject toJson() => {'seconds': seconds, 'pages': pages, 'finished': finished};
}

enum TasteEventKind { save, remove, open, search, seed, imported, metadata, taxonomy }

class TasteEvent {
  TasteEvent({
    String? id,
    this.epoch = 'initial',
    this.generation = 'initial',
    this.device = '',
    double? at,
    required this.kind,
    required this.item,
    DiscoveryContext? context,
    this.dwell,
    this.signal,
  }) : id = id ?? uuidString(),
       at = at ?? unixSeconds(),
       context = context ?? DiscoveryContext.unknown;

  String id;
  String epoch;
  String generation;
  String device;
  double at;
  TasteEventKind kind;
  TasteItem item;
  DiscoveryContext context;
  TasteDwell? dwell;

  /// Set on feedback carried by an open event. Older peers still decode it as a
  /// non-organic open, so it never reaches their preference evidence.
  String? signal;

  static bool ordered(TasteEvent a, TasteEvent b) => a.at == b.at ? a.id.compareTo(b.id) < 0 : a.at < b.at;
  static int compare(TasteEvent a, TasteEvent b) => a.at == b.at ? a.id.compareTo(b.id) : a.at.compareTo(b.at);

  factory TasteEvent.fromJson(JsonObject json) => TasteEvent(
    id: json.string('id'),
    epoch: json.string('epoch'),
    generation: json.string('generation'),
    device: json.string('device'),
    at: json.number('at'),
    kind: TasteEventKind.values.byName(json.string('kind')),
    item: TasteItem.fromJson(json.object('item')),
    context: DiscoveryContext.fromJson(json.object('context')),
    dwell: json.objectOrNull('dwell') == null ? null : TasteDwell.fromJson(json.object('dwell')),
    signal: json.stringOrNull('signal'),
  );

  JsonObject toJson() =>
      <String, Object?>{
          'id': id,
          'epoch': epoch,
          'generation': generation,
          'device': device,
          'at': at,
          'kind': kind.name,
          'item': item.toJson(),
          'context': context.toJson(),
        }
        ..putIfPresent('dwell', dwell?.toJson())
        ..putIfPresent('signal', signal);
}

enum RecommendationSort {
  recommended,
  latest,
  today,
  week,
  month,
  year,
  trending,
  mostFavorited,
  mostUpvoted,
  mostDiscussed,
  popularWeek,
  popularMonth;

  String get rawValue => name;
  String get id => name;
  static RecommendationSort? fromRawValue(String? value) => values.where((sort) => sort.name == value).firstOrNull;

  String get title => this == recommended ? L10n.text('Recommended') : GallerySort.fromRawValue(rawValue)?.title ?? booruSort?.title ?? L10n.text('Popular');

  // Existing image recommendation preferences stored Popular as `week`.
  BooruSort? get booruSort => this == week ? BooruSort.popular : BooruSort.values.where((sort) => sort.name == rawValue).firstOrNull;

  static List<RecommendationSort> options(TasteMode mode, {BooruEngine? engine}) {
    if (mode == TasteMode.comics) return const [recommended, latest, today, week, month, year];
    return [
      recommended,
      for (final sort in engine == null ? const [BooruSort.latest, BooruSort.popular] : BooruSort.optionsFor(engine))
        if (sort == BooruSort.popular) week else ?fromRawValue(sort.rawValue),
    ];
  }

  String titleFor(TasteMode mode) => mode == TasteMode.booru ? booruSort?.title ?? title : title;
}

class RecommendationPreferences {
  RecommendationPreferences({List<String>? includedTags, this.language = 'all', this.sort = RecommendationSort.recommended})
    : includedTags = includedTags ?? [];
  List<String> includedTags;
  String language;
  RecommendationSort sort;

  RecommendationPreferences copy() => RecommendationPreferences(includedTags: [...includedTags], language: language, sort: sort);

  factory RecommendationPreferences.fromJson(JsonObject json) => RecommendationPreferences(
    includedTags: json.stringsOrNull('includedTags') ?? [],
    language: json.stringOrNull('language') ?? 'all',
    sort: RecommendationSort.fromRawValue(json.stringOrNull('sort')) ?? RecommendationSort.recommended,
  );
  JsonObject toJson() => {'includedTags': includedTags, 'language': language, 'sort': sort.rawValue};

  static const _lists = ListEquality<String>();
  @override
  bool operator ==(Object other) =>
      other is RecommendationPreferences && _lists.equals(other.includedTags, includedTags) && other.language == language && other.sort == sort;
  @override
  int get hashCode => Object.hash(_lists.hash(includedTags), language, sort);
}

/// Taste analysis settings, merged between devices by their timestamps.
class TasteControl {
  TasteControl({
    this.version = 1,
    this.timestamp = 0,
    this.author = '',
    this.epoch = 'initial',
    this.generation = 'initial',
    this.enabled = true,
    this.enabledTimestamp = 0,
    this.enabledAuthor = '',
    this.resetTimestamp = 0,
    this.resetAuthor = '',
    this.cloudEnabled = true,
    String? timeZone,
    Set<String>? excluded,
    this.analysisExclusions,
    this.sourceAnalysisExclusions,
    this.recommendationPreferences,
    this.tasteBoosts,
    this.discoveryLevel,
  }) : timeZone = timeZone ?? currentTimeZone,
       excluded = excluded ?? {};

  /// `TimeZone.current.identifier`, set from the platform when the app starts.
  static String currentTimeZone = 'UTC';

  int version;
  double timestamp;
  String author;
  String epoch;
  String generation;
  bool enabled;
  double enabledTimestamp;
  String enabledAuthor;
  double resetTimestamp;
  String resetAuthor;
  bool cloudEnabled;
  String timeZone;
  Set<String> excluded;
  // Optional for backward-compatible decoding of existing local and synced controls.
  Map<String, List<String>>? analysisExclusions;
  Map<String, List<String>>? sourceAnalysisExclusions;
  Map<String, RecommendationPreferences>? recommendationPreferences;

  /// Explicit steering of the learned profile, by tag key: +1 more, -1 less.
  Map<String, int>? tasteBoosts;

  /// 0 stays close to known taste, 1 is balanced, 2 reaches further out.
  int? discoveryLevel;

  TasteControl copy() => TasteControl.fromJson(toJson());

  int boost(String key) => tasteBoosts?[key] ?? 0;
  void setBoost(int value, String key) {
    final boosts = tasteBoosts ??= {};
    value == 0 ? boosts.remove(key) : boosts[key] = value;
  }

  RecommendationPreferences preferences(String source) => recommendationPreferences?[source]?.copy() ?? RecommendationPreferences();
  void setPreferences(RecommendationPreferences value, String source) => (recommendationPreferences ??= {})[source] = value.copy();

  Set<String> analysisExcludedFor(TasteMode mode, {String? source}) {
    final saved = source == null ? null : sourceAnalysisExclusions?[source];
    if (saved != null) return saved.map((tag) => normalizeAnalysisExclusion(tag, mode)).toSet();
    final general = analysisExclusions?[mode.name];
    if (general != null) return general.map((tag) => normalizeAnalysisExclusion(tag, mode)).toSet();
    return mode == TasteMode.comics ? {'female:sole_female', 'male:sole_male', 'tag:digital', 'tag:group'} : {'1girl', '1boy', 'solo'};
  }

  void setAnalysisExcluded(Set<String> tags, TasteMode mode, {String? source}) {
    if (source != null) {
      (sourceAnalysisExclusions ??= {})[source] = (tags.map((tag) => normalizeAnalysisExclusion(tag, mode)).toSet().toList()..sort());
    } else {
      (analysisExclusions ??= {})[mode.name] = (tags.map((tag) => normalizeAnalysisExclusion(tag, mode)).where((tag) => tag.isNotEmpty).toSet().toList()
        ..sort());
    }
  }

  static String normalizeExclusion(String value) =>
      value.split(':').map((part) => part.toLowerCase().split(RegExp(r'[\s_]+')).where((piece) => piece.isNotEmpty).join('_')).join(':');

  // Repair the original default spelling at the exclusion boundary only.
  // Keep stored artwork tags, search queries and statistical identities unchanged.
  static String normalizeAnalysisExclusion(String value, TasteMode mode) {
    final normalized = normalizeExclusion(value);
    if (mode != TasteMode.comics) return normalized;
    return switch (normalized) {
      'female:solo_female' => 'female:sole_female',
      'male:solo_male' => 'male:sole_male',
      'solo_female' => 'sole_female',
      'solo_male' => 'sole_male',
      _ => normalized,
    };
  }

  bool allows(String tag, {required String source, required TasteMode mode}) {
    final normalized = normalizeAnalysisExclusion(tag, mode);
    bool matches(String exclusion) {
      final blocked = normalizeAnalysisExclusion(exclusion, mode);
      if (normalized == blocked) return true;
      // Older metadata/imports stored tag values without namespaces.
      // Match those exact legacy values, never a different explicit namespace.
      final colon = blocked.indexOf(':');
      if (mode != TasteMode.comics || normalized.contains(':') || colon < 0 || !const {'female', 'male', 'tag'}.contains(blocked.substring(0, colon))) {
        return false;
      }
      return normalized == blocked.substring(colon + 1);
    }

    return !analysisExcludedFor(mode, source: source).any(matches) &&
        !excluded.any((key) {
          final parts = key.split('\n');
          return parts.length == 2 && parts[0] == source && matches(parts[1]);
        });
  }

  String analysisKey(TasteMode mode) {
    final values = [epoch, timeZone, '$enabled', ...(analysisExcludedFor(mode).toList()..sort()), ...(excluded.toList()..sort())];
    return tasteDigest([...encodeJson(values), ...encodeJson(sourceAnalysisExclusions)]);
  }

  bool newer(TasteControl other) => timestamp == other.timestamp ? author.compareTo(other.author) > 0 : timestamp > other.timestamp;

  TasteControl merged(TasteControl other) {
    final result = (other.newer(this) ? other : this).copy();
    final reset = other.resetTimestamp > resetTimestamp || (other.resetTimestamp == resetTimestamp && other.resetAuthor.compareTo(resetAuthor) > 0)
        ? other
        : this;
    result
      ..epoch = reset.epoch
      ..resetTimestamp = reset.resetTimestamp
      ..resetAuthor = reset.resetAuthor;
    final permission =
        other.enabledTimestamp > enabledTimestamp || (other.enabledTimestamp == enabledTimestamp && other.enabledAuthor.compareTo(enabledAuthor) > 0)
        ? other
        : this;
    result
      ..enabled = permission.enabled
      ..enabledTimestamp = permission.enabledTimestamp
      ..enabledAuthor = permission.enabledAuthor
      ..generation = permission.generation;
    return result;
  }

  static String tagKey({required String source, required String tag}) => '$source\n$tag';

  factory TasteControl.fromJson(JsonObject json) => TasteControl(
    version: json.integer('version'),
    timestamp: json.number('timestamp'),
    author: json.string('author'),
    epoch: json.string('epoch'),
    generation: json.string('generation'),
    enabled: json.boolean('enabled'),
    enabledTimestamp: json.number('enabledTimestamp'),
    enabledAuthor: json.string('enabledAuthor'),
    resetTimestamp: json.number('resetTimestamp'),
    resetAuthor: json.string('resetAuthor'),
    cloudEnabled: json.boolean('cloudEnabled'),
    timeZone: json.string('timeZone'),
    excluded: json.strings('excluded').toSet(),
    analysisExclusions: json.dictionaryOrNull('analysisExclusions', (value) => (value as List).map(jsonString).toList()),
    sourceAnalysisExclusions: json.dictionaryOrNull('sourceAnalysisExclusions', (value) => (value as List).map(jsonString).toList()),
    recommendationPreferences: json.dictionaryOrNull('recommendationPreferences', (value) => RecommendationPreferences.fromJson(jsonObject(value))),
    tasteBoosts: json.dictionaryOrNull('tasteBoosts', jsonInteger),
    discoveryLevel: json.integerOrNull('discoveryLevel'),
  );

  // Wire-only retirement flags keep older app versions able to decode controls.
  JsonObject toJson() =>
      <String, Object?>{
          'aiEnabled': false,
          'version': version,
          'timestamp': timestamp,
          'author': author,
          'epoch': epoch,
          'generation': generation,
          'enabled': enabled,
          'enabledTimestamp': enabledTimestamp,
          'enabledAuthor': enabledAuthor,
          'resetTimestamp': resetTimestamp,
          'resetAuthor': resetAuthor,
          'cloudEnabled': cloudEnabled,
          'timeZone': timeZone,
          'excluded': excluded.toList()..sort(),
        }
        ..putIfPresent('analysisExclusions', analysisExclusions)
        ..putIfPresent('sourceAnalysisExclusions', sourceAnalysisExclusions)
        ..putIfPresent('recommendationPreferences', recommendationPreferences?.map((key, value) => MapEntry(key, value.toJson())))
        ..putIfPresent('tasteBoosts', tasteBoosts)
        ..putIfPresent('discoveryLevel', discoveryLevel);
}

class TasteTag {
  TasteTag({
    required this.source,
    required this.name,
    this.confirmed = 0,
    this.hidden = 0,
    this.general = 0,
    this.searches = 0,
    this.opened = 0,
    Set<String>? sessions,
    List<TasteItem>? works,
    this.lift,
    this.previouslySearched = false,
  }) : sessions = sessions ?? {},
       works = works ?? [];

  String source;
  String name;
  int confirmed;
  int hidden;
  int general;
  int searches;
  int opened;
  Set<String> sessions;
  List<TasteItem> works;
  double? lift;
  bool previouslySearched;

  String get id => TasteControl.tagKey(source: source, tag: name);
  bool get discovery => !previouslySearched && hidden >= 5 && sessions.length >= 3 && (lift == null || lift! > 1);
  int get count => confirmed + hidden + general;
  double get weight => math.log(1 + count) * (lift == null ? 1 : math.min(3, math.max(0.25, lift!)));

  @override
  bool operator ==(Object other) =>
      other is TasteTag &&
      other.source == source &&
      other.name == name &&
      other.confirmed == confirmed &&
      other.hidden == hidden &&
      other.general == general &&
      other.searches == searches &&
      other.opened == opened &&
      other.lift == lift &&
      other.previouslySearched == previouslySearched &&
      const SetEquality<String>().equals(other.sessions, sessions);
  @override
  int get hashCode => Object.hash(source, name, confirmed, hidden, general, searches, opened, lift, previouslySearched);
}

class TasteSnapshot {
  TasteSnapshot({
    required this.tags,
    required this.saves,
    required this.opens,
    required this.searches,
    required this.activity,
    required this.digest,
    this.period,
    this.previousSaves,
    Map<String, int>? previousTagCounts,
  }) : previousTagCounts = previousTagCounts ?? {};

  List<TasteTag> tags;
  int saves;
  int opens;
  int searches;

  /// Saves per day, keyed by the start of each day in the analysis time zone.
  Map<DateTime, int> activity;
  String digest;
  TasteInterval? period;
  int? previousSaves;
  Map<String, int> previousTagCounts;

  TasteSnapshot copy() => TasteSnapshot(
    tags: [...tags],
    saves: saves,
    opens: opens,
    searches: searches,
    activity: {...activity},
    digest: digest,
    period: period,
    previousSaves: previousSaves,
    previousTagCounts: {...previousTagCounts},
  );
}

/// `DateInterval`: from [start] up to, not including, [end].
class TasteInterval {
  const TasteInterval(this.start, this.end);
  final DateTime start;
  final DateTime end;
  double get startSeconds => unixSeconds(start);
  double get endSeconds => unixSeconds(end);
  bool contains(double at) => at >= startSeconds && at < endSeconds;

  @override
  bool operator ==(Object other) => other is TasteInterval && other.start == start && other.end == end;
  @override
  int get hashCode => Object.hash(start, end);
  @override
  String toString() => 'TasteInterval($start, $end)';
}

/// The Gregorian calendar of the analysis time zone, with ISO weeks (Monday first,
/// four days in the first week). Dart has no time zone database, so a zone that is
/// neither UTC nor the device's own falls back to the device's local time.
class TasteCalendar {
  TasteCalendar(String timeZone) : utc = const {'UTC', 'GMT', 'Etc/UTC', 'Etc/GMT', 'Z'}.contains(timeZone);
  final bool utc;

  DateTime date(int year, [int month = 1, int day = 1, int hour = 0]) => utc ? DateTime.utc(year, month, day, hour) : DateTime(year, month, day, hour);
  DateTime local(DateTime moment) => utc ? moment.toUtc() : moment.toLocal();
  DateTime fromSeconds(double seconds) => local(DateTime.fromMicrosecondsSinceEpoch((seconds * 1e6).round(), isUtc: true));
  DateTime startOfDay(DateTime moment) {
    final value = local(moment);
    return date(value.year, value.month, value.day);
  }

  DateTime addDays(DateTime day, int count) {
    final value = local(day);
    return date(value.year, value.month, value.day + count);
  }

  int hour(DateTime moment) => local(moment).hour;

  /// 1 is Sunday and 7 is Saturday, as `Calendar.component(.weekday)` reports.
  int weekday(DateTime moment) => local(moment).weekday % 7 + 1;

  TasteInterval week(DateTime moment) {
    final value = local(moment);
    final start = date(value.year, value.month, value.day - (value.weekday - 1));
    return TasteInterval(start, addDays(start, 7));
  }

  TasteInterval month(DateTime moment) {
    final value = local(moment);
    return TasteInterval(date(value.year, value.month), date(value.year, value.month + 1));
  }

  TasteInterval year(DateTime moment) {
    final value = local(moment);
    return TasteInterval(date(value.year), date(value.year + 1));
  }

  DateTime addMonths(DateTime moment, int count) {
    final value = local(moment);
    final target = date(value.year, value.month + count);
    final lastDay = date(target.year, target.month + 1, 0).day;
    return date(target.year, target.month, math.min(value.day, lastDay), value.hour);
  }

  DateTime addYears(DateTime moment, int count) => addMonths(moment, count * 12);
}

enum TastePeriod {
  recommendations,
  week,
  month,
  year;

  String get id => name;
  String get title => switch (this) {
    recommendations => L10n.text('Recommendations'),
    week => L10n.text('Weekly'),
    month => L10n.text('Monthly'),
    year => L10n.text('Yearly'),
  };

  TasteInterval? interval({required int offset, required DateTime now, required String timeZone}) {
    final calendar = TasteCalendar(timeZone);
    return switch (this) {
      recommendations => null,
      week => calendar.week(now.add(Duration(days: 7 * offset))),
      month => calendar.month(calendar.addMonths(now, offset)),
      year => calendar.year(calendar.addYears(now, offset)),
    };
  }
}

enum TasteSignal { dismissed, restored }

String tasteDigest(List<int> data) => sha256.convert(data).toString();
String tasteDigestOf(String text) => tasteDigest(utf8.encode(text));
