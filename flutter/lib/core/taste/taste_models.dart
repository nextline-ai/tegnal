import 'dart:convert';

import 'package:collection/collection.dart';
import 'package:crypto/crypto.dart';

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

/// Taste analysis settings. Only the fields are ported so far; the analysis
/// methods arrive with the taste screens.
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
  Map<String, List<String>>? analysisExclusions;
  Map<String, List<String>>? sourceAnalysisExclusions;
  Map<String, Object?>? recommendationPreferences;
  Map<String, int>? tasteBoosts;
  int? discoveryLevel;

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
    recommendationPreferences: json.objectOrNull('recommendationPreferences'),
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
        ..putIfPresent('recommendationPreferences', recommendationPreferences)
        ..putIfPresent('tasteBoosts', tasteBoosts)
        ..putIfPresent('discoveryLevel', discoveryLevel);
}

String tasteDigest(List<int> data) => sha256.convert(data).toString();
String tasteDigestOf(String text) => tasteDigest(utf8.encode(text));
