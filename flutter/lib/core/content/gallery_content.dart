import 'dart:convert';
import 'dart:typed_data';

import 'package:characters/characters.dart';
import 'package:collection/collection.dart';

import '../support/l10n.dart';
import '../storage/work_identity.dart';
import '../support/swift_json.dart';
import 'content_errors.dart';
import 'content_url.dart';
import 'gallery_id_parser.dart';
import 'keyed_catalog_source.dart';
import 'manga_urls.dart';
import 'site_account.dart';

class GalleryPage {
  const GalleryPage({
    required this.hash,
    required this.name,
    required this.width,
    required this.height,
    required this.hasAVIF,
    this.imageURL,
    this.thumbnailURL,
    this.index,
    this.sourceSite,
  });

  final String hash;
  final String name;
  final int width;
  final int height;
  final bool hasAVIF;
  final Uri? imageURL;
  final Uri? thumbnailURL;
  final int? index;
  final String? sourceSite;

  /// The optional descriptors are absent from works downloaded before they existed.
  factory GalleryPage.fromJson(JsonObject json) => GalleryPage(
    hash: json.string('hash'),
    name: json.string('name'),
    width: json.integer('width'),
    height: json.integer('height'),
    hasAVIF: json.boolean('hasAVIF'),
    imageURL: json.stringOrNull('imageURL').map(Uri.parse),
    thumbnailURL: json.stringOrNull('thumbnailURL').map(Uri.parse),
    index: json.integerOrNull('index'),
    sourceSite: json.stringOrNull('sourceSite'),
  );

  JsonObject toJson() => <String, Object?>{'hash': hash, 'name': name, 'width': width, 'height': height, 'hasAVIF': hasAVIF}
    ..putIfPresent('imageURL', imageURL?.toString())
    ..putIfPresent('thumbnailURL', thumbnailURL?.toString())
    ..putIfPresent('index', index)
    ..putIfPresent('sourceSite', sourceSite);

  @override
  bool operator ==(Object other) =>
      other is GalleryPage &&
      other.hash == hash &&
      other.name == name &&
      other.width == width &&
      other.height == height &&
      other.hasAVIF == hasAVIF &&
      other.imageURL == imageURL &&
      other.thumbnailURL == thumbnailURL &&
      other.index == index &&
      other.sourceSite == sourceSite;
  @override
  int get hashCode => Object.hash(hash, name, index, sourceSite);
}

extension<T extends Object> on T? {
  R? map<R>(R Function(T value) transform) => this == null ? null : transform(this as T);
}

/// One language of a work. Each language is a gallery with its own number.
class GalleryVersion {
  const GalleryVersion({required this.id, required this.language, this.localName});
  final int id;
  final String language;
  final String? localName;

  String get displayName => (localName?.isNotEmpty ?? false) ? localName! : capitalized(language);

  factory GalleryVersion.fromJson(JsonObject json) =>
      GalleryVersion(id: json.integer('id'), language: json.string('language'), localName: json.stringOrNull('localName'));
  JsonObject toJson() => <String, Object?>{'id': id, 'language': language}..putIfPresent('localName', localName);

  @override
  bool operator ==(Object other) => other is GalleryVersion && other.id == id && other.language == language && other.localName == localName;
  @override
  int get hashCode => Object.hash(id, language, localName);
}

/// `String.capitalized`: each word starts upper case, the rest lower case.
String capitalized(String value) =>
    value.toLowerCase().replaceAllMapped(RegExp(r'(^|[^\p{L}\p{N}])(\p{L})', unicode: true), (match) => '${match[1]}${match[2]!.toUpperCase()}');

class NativeGallery {
  const NativeGallery({
    required this.id,
    required this.title,
    required this.artists,
    required this.language,
    required this.type,
    required this.tags,
    required this.pages,
    this.versions,
    this.relatedIDs,
    this.listedTitles,
    this.listedPageCount,
  });

  final int id;
  final String title;
  final List<String> artists;
  final String language;
  final String type;
  final List<String> tags;
  final List<GalleryPage> pages;

  /// Optional so works downloaded before these were read still decode.
  final List<GalleryVersion>? versions;
  final List<int>? relatedIDs;

  /// Every title the website lists, and the page count when the pages themselves are not
  /// listed yet: what tells one work listed by two websites apart.
  final List<String>? listedTitles;
  final int? listedPageCount;

  WorkFingerprint get matchFingerprint => WorkMatcher.fingerprint(
    titles: [...?listedTitles, title],
    artists: artists,
    pages: listedPageCount ?? (pages.length > 1 ? pages.length : 0),
  );

  /// The other languages of this work, with the given language first.
  List<GalleryVersion> otherVersions(String preferring) {
    final others = (versions ?? []).where((version) => version.id != id).toList();
    return [...others.where((version) => version.language == preferring), ...others.where((version) => version.language != preferring)];
  }

  /// The version to offer someone who wants this language, unless this already is it.
  GalleryVersion? suggestedVersion(String language) {
    if (this.language.toLowerCase() == language.toLowerCase()) return null;
    return otherVersions(language).where((version) => version.language.toLowerCase() == language.toLowerCase()).firstOrNull;
  }

  /// Default exclusions only reach searches, so works reached another way check them here.
  bool isExcluded(String terms) {
    String normal(String text) => text.toLowerCase().replaceAll('_', ' ');
    final labels = [...tags, ...artists.map((artist) => 'artist:$artist'), 'language:$language', 'type:$type'].map(normal).toSet();
    final names = labels.map((label) => swiftSplit(label, (character) => character == ':', maxSplits: 1).lastOrNull).nonNulls.toSet();
    return swiftSplit(terms, (character) => isWhitespace(character) || character == ',').any((token) {
      final term = normal(token.replaceFirst(RegExp('^-+'), ''));
      if (term.isEmpty) return false;
      return term.contains(':') ? labels.contains(term) : names.contains(term) || normal(title).contains(term);
    });
  }

  static NativeGallery parse(List<int> data, int id) {
    if (id <= 0 || data.length > 4000000) throw ContentError.invalidResponse;
    String text;
    try {
      text = utf8.decode(data);
    } on FormatException {
      throw ContentError.invalidResponse;
    }
    text = text.trim();
    final match = RegExp(r'^var\s+galleryinfo\s*=\s*').firstMatch(text);
    if (match == null) throw ContentError.unsupportedFormat;
    text = text.substring(match.end);
    if (text.endsWith(';')) text = text.substring(0, text.length - 1);
    final Object? json;
    try {
      json = jsonDecode(text);
    } on FormatException {
      throw ContentError.invalidResponse;
    }
    if (json is! Map<String, Object?>) throw ContentError.invalidResponse;
    final files = json['files'];
    if (files is! List || files.isEmpty || files.length > 10000 || files.any((file) => file is! Map)) throw ContentError.invalidResponse;
    final pages = <GalleryPage>[];
    for (final (index, file) in files.cast<Map>().indexed) {
      final hash = file['hash'], name = file['name'];
      if (hash is! String || !validPageHash(hash) || name is! String || name.isEmpty) throw ContentError.unsupportedFormat;
      pages.add(
        GalleryPage(
          hash: hash,
          name: name,
          width: _number(file['width'])?.toInt() ?? 0,
          height: _number(file['height'])?.toInt() ?? 0,
          hasAVIF: (_number(file['hasavif']) ?? 0) != 0,
          index: index,
          sourceSite: MangaUrls.home,
        ),
      );
    }
    final japanese = (json['japanese_title'] is String ? json['japanese_title'] as String : null)?.trim();
    final title = (japanese?.isNotEmpty ?? false) ? japanese! : (json['title'] is String ? json['title'] as String : L10n.text('Work %@', ['$id']));
    return NativeGallery(
      id: id,
      title: decodeEntities(title),
      artists: [
        for (final item in _objects(json['artists']))
          if (item['artist'] case final String artist) artist,
      ],
      language: json['language'] is String ? json['language'] as String : '',
      type: json['type'] is String ? json['type'] as String : '',
      tags: [...parseCredits(json), ...parseTags(json['tags'])],
      pages: pages,
      listedTitles: [
        if (json['title'] case final String value) decodeEntities(value),
        if (japanese case final String value when value.isNotEmpty) decodeEntities(value),
      ],
      versions: parseVersions(json['languages']),
      relatedIDs: parseRelatedIDs(json['related']),
    );
  }

  /// A JSON number as `NSNumber` reads it, where `true` is one.
  static num? _number(Object? value) => value is num
      ? value
      : value is bool
      ? (value ? 1 : 0)
      : null;

  static List<Map<String, Object?>> _objects(Object? value) =>
      value is List && value.every((item) => item is Map) ? value.cast<Map>().map((item) => item.cast<String, Object?>()).toList() : [];

  static List<GalleryVersion> parseVersions(Object? value) {
    final seen = <int>{};
    return [
      for (final item in _objects(value))
        if (_galleryID(item['galleryid']) case final id?)
          if (item['name'] case final String language when language.isNotEmpty && seen.add(id))
            GalleryVersion(id: id, language: language, localName: item['language_localname'] is String ? item['language_localname'] as String : null),
    ];
  }

  static List<int> parseRelatedIDs(Object? value) {
    final seen = <int>{};
    return (value is List ? value : const []).map(_galleryID).nonNulls.where(seen.add).take(12).toList();
  }

  static int? _galleryID(Object? value) {
    final id = value is num ? value.toInt() : (value is String ? parseInt64(value) : null);
    return id != null && id > 0 ? id : null;
  }

  static bool validPageHash(String hash) => RegExp(r'^[0-9a-f]{64}$').hasMatch(hash);

  static List<String> parseTags(Object? value) => [
    for (final item in _objects(value))
      if (item['tag'] case final String tag)
        for (final namespace in ['female', 'male'].where((name) => _flag(item[name])).toList().orIfEmpty(['tag'])) '$namespace:$tag',
  ];

  /// Groups, series and characters come in their own lists, so they read as namespaced tags.
  static List<String> parseCredits(Map<String, Object?> json) => [
    for (final (list, key, namespace) in [('groups', 'group', 'group'), ('parodys', 'parody', 'series'), ('characters', 'character', 'character')])
      for (final item in _objects(json[list]))
        if (item[key] case final String value when value.isNotEmpty) '$namespace:$value',
  ];

  static bool _flag(Object? value) {
    final number = _number(value);
    if (number != null) return number != 0;
    return ['1', 'true'].contains((value is String ? value : '').toLowerCase());
  }

  static const _namedEntities = {'amp': '&', 'lt': '<', 'gt': '>', 'quot': '"', 'apos': "'", 'nbsp': ' '};
  static final _entityRegex = RegExp(r'&(#x[0-9a-fA-F]+|#[0-9]+|[a-z]+);');

  static String decodeEntities(String input) {
    if (!input.contains('&')) return input;
    return input.replaceAllMapped(_entityRegex, (match) {
      final token = match[1]!;
      var replacement = _namedEntities[token];
      if (token.startsWith('#')) {
        final hex = token.startsWith('#x');
        final code = int.tryParse(token.substring(hex ? 2 : 1), radix: hex ? 16 : 10);
        if (code != null && code <= 0x10FFFF && !(code >= 0xD800 && code <= 0xDFFF)) replacement = String.fromCharCode(code);
      }
      return replacement ?? match[0]!;
    });
  }

  factory NativeGallery.fromJson(JsonObject json) => NativeGallery(
    id: json.integer('id'),
    title: json.string('title'),
    artists: json.strings('artists'),
    language: json.string('language'),
    type: json.string('type'),
    tags: json.strings('tags'),
    pages: json.list('pages', (value) => GalleryPage.fromJson(jsonObject(value))),
    versions: json.listOrNull('versions', (value) => GalleryVersion.fromJson(jsonObject(value))),
    relatedIDs: json.listOrNull('relatedIDs', jsonInteger),
  );

  JsonObject toJson() =>
      <String, Object?>{
          'id': id,
          'title': title,
          'artists': artists,
          'language': language,
          'type': type,
          'tags': tags,
          'pages': [for (final page in pages) page.toJson()],
        }
        ..putIfPresent('versions', versions?.map((version) => version.toJson()).toList())
        ..putIfPresent('relatedIDs', relatedIDs);

  NativeGallery copyWith({List<GalleryPage>? pages}) => NativeGallery(
    id: id,
    title: title,
    artists: artists,
    language: language,
    type: type,
    tags: tags,
    pages: pages ?? this.pages,
    versions: versions,
    relatedIDs: relatedIDs,
    listedTitles: listedTitles,
    listedPageCount: listedPageCount,
  );
}

extension on List<String> {
  List<String> orIfEmpty(List<String> fallback) => isEmpty ? fallback : this;
}

enum GallerySort {
  latest,
  today,
  week,
  month,
  year;

  String get rawValue => name;
  static GallerySort? fromRawValue(String value) => values.where((sort) => sort.name == value).firstOrNull;

  /// Keyed catalogs only rank what is popular right now.
  static List<GallerySort> get available =>
      MangaUrls.hasResolvedBackend && MangaUrls.backend == MangaBackend.keyed ? const [GallerySort.latest, GallerySort.today] : values;

  String get title => switch (this) {
    latest => L10n.text('Latest'),
    today => L10n.text('Popular Today'),
    week => L10n.text('Popular This Week'),
    month => L10n.text('Popular This Month'),
    year => L10n.text('Popular This Year'),
  };
}

class GalleryQuery {
  const GalleryQuery({this.language = 'korean', this.artist, this.text = '', this.sort = GallerySort.latest, this.allowsLanguageExceptions = false});

  static const maximumSearchTerms = 64;
  final String language;
  final String? artist;
  final String text;
  final GallerySort sort;
  final bool allowsLanguageExceptions;

  GalleryQuery copyWith({String? language, String? artist, bool clearArtist = false, String? text, GallerySort? sort, bool? allowsLanguageExceptions}) =>
      GalleryQuery(
        language: language ?? this.language,
        artist: clearArtist ? null : artist ?? this.artist,
        text: text ?? this.text,
        sort: sort ?? this.sort,
        allowsLanguageExceptions: allowsLanguageExceptions ?? this.allowsLanguageExceptions,
      );

  GalleryQuery applyingDefaults({required String tags, required String excluded}) {
    final explicit = splitWhitespace(text);
    final includes = splitWhitespace(tags);
    final excludes = splitWhitespace(excluded).map((term) => '-${term.replaceFirst(RegExp('^-+'), '')}');
    final seen = <String>{};
    return copyWith(text: [...explicit, ...includes, ...excludes].where(seen.add).join(' '));
  }

  /// Narrows to one category unless the search already names one or the site lacks it.
  GalleryQuery filteredTo(String category) {
    final terms = splitWhitespace(text);
    if (!GalleryCategory.available.contains(category) || terms.any((term) => term.startsWith('type:'))) return this;
    return copyWith(text: [...terms, 'type:$category'].join(' '));
  }

  @override
  bool operator ==(Object other) =>
      other is GalleryQuery &&
      other.language == language &&
      other.artist == artist &&
      other.text == text &&
      other.sort == sort &&
      other.allowsLanguageExceptions == allowsLanguageExceptions;
  @override
  int get hashCode => Object.hash(language, artist, text, sort, allowsLanguageExceptions);
  @override
  String toString() => 'GalleryQuery($language, $artist, "$text", ${sort.name}, $allowsLanguageExceptions)';
}

/// Work categories as the comics protocols name them.
abstract final class GalleryCategory {
  static const _common = ['doujinshi', 'manga', 'artistcg', 'gamecg', 'imageset'];

  /// What the connected site can filter by. Until its protocol is known, only categories every protocol has.
  static List<String> get available {
    if (!MangaUrls.hasResolvedBackend) return _common;
    return MangaUrls.backend == MangaBackend.indexed ? [..._common, 'anime'] : [..._common, 'western', 'non-h', 'cosplay', 'photo', 'misc'];
  }

  /// One spelling per category, whichever way a site or an imported catalog wrote it.
  static String key(String type) => type.toLowerCase().replaceAll(RegExp(r'[^\p{L}\p{N}-]', unicode: true), '');

  static String title(String type) => switch (key(type)) {
    'doujinshi' => L10n.text('Doujinshi'),
    'manga' => L10n.text('Manga'),
    'artistcg' => L10n.text('Artist CG'),
    'gamecg' => L10n.text('Game CG'),
    'imageset' => L10n.text('Image Set'),
    'anime' => L10n.text('Anime'),
    'western' => L10n.text('Western'),
    'non-h' => L10n.text('Non-H'),
    'cosplay' => L10n.text('Cosplay'),
    'photo' => L10n.text('Photo'),
    'misc' => L10n.text('Misc'),
    'private' => L10n.text('Private'),
    _ => capitalized(type),
  };
}

/// Turns a work's related numbers into what is worth showing beside it.
abstract final class RelatedWorks {
  static Future<List<int>> load(NativeGallery gallery, ContentProviding source, {required Set<int> hidden, required String excluded}) async {
    final related = gallery.relatedIDs ?? [];
    final loaded = await Future.wait(
      related.map((id) async {
        try {
          return await source.gallery(id);
        } on Object {
          return null;
        }
      }),
    );
    return select(loaded.nonNulls.toList(), gallery, hidden: hidden, excluded: excluded);
  }

  /// Keeps the site's order, drops other languages of works already shown,
  /// and prefers the language of the work being read.
  static List<int> select(List<NativeGallery> works, NativeGallery gallery, {required Set<int> hidden, required String excluded}) {
    final seen = {gallery.id, ...(gallery.versions ?? []).map((version) => version.id)};
    final result = <int>[];
    for (final work in works) {
      final family = {work.id, ...(work.versions ?? []).map((version) => version.id)};
      if (seen.intersection(family).isNotEmpty || work.isExcluded(excluded)) continue;
      seen.addAll(family);
      final shown = work.suggestedVersion(gallery.language)?.id ?? work.id;
      if (!hidden.contains(work.id) && !hidden.contains(shown)) result.add(shown);
    }
    return result;
  }
}

/// Artists open in every language until a person picks one, and that choice stays.
abstract final class ArtistBrowsing {
  static const preferenceKey = 'manga.artistLanguage';
  static String get language => ContentPreferences.defaults.string(preferenceKey) ?? 'all';
  static set language(String value) => ContentPreferences.defaults.set(preferenceKey, value);

  static bool matches(String query) {
    final terms = splitWhitespace(query);
    return terms.length == 1 && terms[0].toLowerCase().startsWith('artist:');
  }
}

/// Opening a single tag, as from a work's tags, starts in the language chosen for tags, the way
/// artists start in theirs. Every language until a person picks one, and that choice stays.
abstract final class TagBrowsing {
  static const preferenceKey = 'manga.tagLanguage';
  static String get language => ContentPreferences.defaults.string(preferenceKey) ?? 'all';
  static set language(String value) => ContentPreferences.defaults.set(preferenceKey, value);

  /// One namespaced term that names a tag, not an artist, a language or a free word.
  static bool matches(String query) {
    final terms = splitWhitespace(query);
    if (terms.length != 1) return false;
    final colon = terms[0].indexOf(':');
    if (colon <= 0 || colon == terms[0].length - 1) return false;
    return !const ['artist', 'language'].contains(terms[0].substring(0, colon).toLowerCase());
  }
}

class GalleryBatch {
  const GalleryBatch({required this.ids, required this.hasMore});
  final List<int> ids;
  final bool hasMore;

  @override
  String toString() => 'GalleryBatch($ids, hasMore: $hasMore)';
}

/// What the explore, detail and reader screens read works from.
abstract class ContentProviding {
  Future<List<TagSuggestion>> suggestions(String token) async => [];
  Future<NativeGallery> gallery(int id);
  Future<GalleryBatch> list(GalleryQuery query, {required int offset, required int count});
  Future<Uint8List> image(GalleryPage page, {required int galleryID, required bool thumbnail});
  NativeGallery? cachedGallery(int id) => null;
  NativeGallery? cachedPreview(int id) => cachedGallery(id);
}

sealed class ContentRoute {
  const ContentRoute();

  /// Rebuild saved native links after the configured server's protocol is known.
  static Uri configuredURL(Uri url) {
    final String address;
    switch (initial(url.toString())) {
      case ReaderRoute(:final id, :final page):
        address = MangaUrls.readerUrl(id, page: page);
      case GalleryRoute(:final id):
        address = MangaUrls.galleryUrl(id);
      case ArtistRoute(:final name):
        address = MangaUrls.artistAllUrl(name);
      default:
        return url;
    }
    return ContentURL.parse(address) ?? url;
  }

  static ContentRoute? initial(String raw) {
    final url = Uri.tryParse(raw);
    if (url == null || url.scheme != 'https' || MangaUrls.configuredHost.isEmpty || url.host.toLowerCase() != MangaUrls.configuredHost) return null;
    if (url.path.startsWith('/g/')) {
      final link = KeyedCatalogSource.links(url.path).firstOrNull;
      if (link != null) {
        GalleryKeys.shared.remember(link.id, link.key);
        return GalleryRoute(link.id);
      }
    }
    // The site's own search form writes spaces as plus signs.
    final keyed = ContentURL.percentEncodedQueryItems(url).where((item) => item.$1 == 'f_search').firstOrNull?.$2;
    if (keyed != null) {
      final search = ContentURL.removingPercentEncoding(keyed.replaceAll('+', '%20'));
      if (search != null) return _keyedSearch(search);
    }
    final id = GalleryIDParser.parse(raw).firstOrNull;
    if (id != null) {
      if (url.path.startsWith('/reader/') || (url.path.startsWith('/r/') && url.hasFragment)) {
        final page = int.tryParse(url.hasFragment ? url.fragment : '1') ?? 1;
        return ReaderRoute(id, page < 1 ? 1 : page);
      }
      return GalleryRoute(id);
    }
    final search = ContentURL.queryValue(url, 'search');
    if (search != null && search.trim().isNotEmpty) return QueryRoute(search);
    final last = url.pathSegments.lastOrNull ?? '';
    if (url.path.startsWith('/artist/') && last.endsWith('-all.html')) return ArtistRoute(last.substring(0, last.length - '-all.html'.length));
    return null;
  }

  /// Reads a keyed catalog's own search back into the app's tag spelling.
  static ContentRoute? _keyedSearch(String search) {
    final text = search.trim();
    if (text.startsWith('gid:')) {
      final id = parseInt64(text.substring(4));
      if (id != null && id > 0) return GalleryRoute(id);
    }
    final words = _tokens(text)
        .map((token) {
          var word = token.endsWith(r'$') ? token.substring(0, token.length - 1) : token;
          final excluded = word.startsWith('-');
          if (excluded) word = word.substring(1);
          if (word.startsWith('parody:')) word = 'series:${word.substring(7)}';
          if (word.startsWith('other:')) word = 'tag:${word.substring(6)}';
          return (excluded ? '-' : '') + word.replaceAll(' ', '_');
        })
        .where((word) => word.isNotEmpty)
        .toList();
    return words.isEmpty ? null : QueryRoute(words.join(' '));
  }

  /// Splits on spaces outside quotes, dropping the quotes.
  static List<String> _tokens(String text) {
    final result = <String>[];
    var current = StringBuffer();
    var quoted = false;
    for (final character in text.characters) {
      if (character == '"') {
        quoted = !quoted;
        continue;
      }
      if (character == ' ' && !quoted) {
        if (current.isNotEmpty) result.add(current.toString());
        current = StringBuffer();
      } else {
        current.write(character);
      }
    }
    if (current.isNotEmpty) result.add(current.toString());
    return result;
  }
}

class DiscoveredGalleryRoute extends ContentRoute {
  const DiscoveredGalleryRoute(this.id, this.context);
  final int id;
  final Object context; // DiscoveryContext
  @override
  bool operator ==(Object other) => other is DiscoveredGalleryRoute && other.id == id && identical(other.context, context);
  @override
  int get hashCode => Object.hash('discoveredGallery', id);
}

class DiscoveredReaderRoute extends ContentRoute {
  const DiscoveredReaderRoute(this.id, this.page, this.context);
  final int id;
  final int page;
  final Object context; // DiscoveryContext
  @override
  bool operator ==(Object other) => other is DiscoveredReaderRoute && other.id == id && other.page == page && identical(other.context, context);
  @override
  int get hashCode => Object.hash('discoveredReader', id, page);
}

class GalleryRoute extends ContentRoute {
  const GalleryRoute(this.id);
  final int id;
  @override
  bool operator ==(Object other) => other is GalleryRoute && other.id == id;
  @override
  int get hashCode => Object.hash('gallery', id);
  @override
  String toString() => 'GalleryRoute($id)';
}

class ReaderRoute extends ContentRoute {
  const ReaderRoute(this.id, this.page);
  final int id;
  final int page;
  @override
  bool operator ==(Object other) => other is ReaderRoute && other.id == id && other.page == page;
  @override
  int get hashCode => Object.hash('reader', id, page);
  @override
  String toString() => 'ReaderRoute($id, $page)';
}

class ArtistRoute extends ContentRoute {
  const ArtistRoute(this.name);
  final String name;
  @override
  bool operator ==(Object other) => other is ArtistRoute && other.name == name;
  @override
  int get hashCode => Object.hash('artist', name);
  @override
  String toString() => 'ArtistRoute($name)';
}

class QueryRoute extends ContentRoute {
  const QueryRoute(this.text);
  final String text;
  @override
  bool operator ==(Object other) => other is QueryRoute && other.text == text;
  @override
  int get hashCode => Object.hash('query', text);
  @override
  String toString() => 'QueryRoute($text)';
}

class TagSuggestion {
  const TagSuggestion({required this.namespace, required this.name, this.count});
  final String namespace;
  final String name;
  final int? count;

  String get id => token;
  String get token => '$namespace:${name.replaceAll(' ', '_')}';

  static const namespaces = {'female', 'male', 'tag', 'artist', 'group', 'series', 'character', 'language', 'type'};

  static List<TagSuggestion> parse(List<int> data) {
    final Object? rows;
    try {
      rows = jsonDecode(utf8.decode(data));
    } on FormatException {
      throw ContentError.invalidResponse;
    }
    if (rows is! List || rows.length > 100 || rows.any((row) => row is! List)) throw ContentError.invalidResponse;
    final seen = <String>{};
    final result = <TagSuggestion>[];
    for (final row in rows.cast<List>()) {
      if (row.length != 3) continue;
      final name = row[0], count = row[1], namespace = row[2];
      if (name is! String || name.isEmpty || name.characters.length > 120 || name.contains(RegExp('[\n\r\u000B\u000C\u0085  ]'))) continue;
      if (count is! int || count < 0 || namespace is! String || !namespaces.contains(namespace)) continue;
      final item = TagSuggestion(namespace: namespace, name: name, count: count);
      if (seen.add(item.id)) result.add(item);
    }
    return result;
  }

  @override
  bool operator ==(Object other) => other is TagSuggestion && other.namespace == namespace && other.name == name && other.count == count;
  @override
  int get hashCode => Object.hash(namespace, name, count);
  @override
  String toString() => 'TagSuggestion($namespace:$name, $count)';
}

class TagCompletionContext {
  TagCompletionContext._(this.prefix, this.excluded, this.token);

  final String prefix;
  final bool excluded;
  final String token;

  static TagCompletionContext? parse(String input) {
    if (input.isEmpty || isWhitespace(input.characters.last)) return null;
    final tail = splitWhitespace(input).lastOrNull;
    if (tail == null) return null;
    final prefix = input.substring(0, input.length - tail.length);
    final excluded = tail.startsWith('-');
    final token = (excluded ? tail.substring(1) : tail).toLowerCase();
    final pieces = token.split(':');
    final term = pieces.last;
    final termLength = term.characters.length;
    if (pieces.length > 2 || token.characters.length > 120) return null;
    if (pieces.length != 1 && !TagSuggestion.namespaces.contains(pieces[0])) return null;
    if (termLength < 2 || termLength > 64 || RegExp(r'^\p{N}+$', unicode: true).hasMatch(term) || term.contains('/') || term.contains('"')) return null;
    return TagCompletionContext._(prefix, excluded, token);
  }

  String inserting(TagSuggestion suggestion) => '$prefix${excluded ? '-' : ''}${suggestion.token} ';

  @override
  bool operator ==(Object other) => other is TagCompletionContext && other.prefix == prefix && other.excluded == excluded && other.token == token;
  @override
  int get hashCode => Object.hash(prefix, excluded, token);
}

/// Deep list equality for test helpers and caches.
const listEquality = ListEquality<Object?>();
