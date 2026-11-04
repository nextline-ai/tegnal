import 'dart:convert';

import '../storage/folder_rules.dart';
import '../support/l10n.dart';
import '../support/swift_json.dart';
import '../support/swift_url.dart';

enum BooruEngine {
  danbooru,
  gelbooru,
  oldGelbooru,
  moebooru;

  String get rawValue => name;
  static BooruEngine fromRawValue(String value) =>
      values.firstWhere((engine) => engine.name == value, orElse: () => throw SwiftJsonError('Unknown engine "$value"'));

  String get title => this == oldGelbooru ? 'Old Gelbooru (v0.1.11)' : '${name[0].toUpperCase()}${name.substring(1)}';
  bool get usesGelbooruPages => this == gelbooru || this == oldGelbooru;
}

class BooruServer {
  BooruServer({String? id, required this.name, required this.baseURL, required this.engine}) : id = id ?? uuidString();

  String id;
  String name;
  String baseURL;
  BooruEngine engine;

  String get displayName => BooruServer.displayNameOf(name);
  static String displayNameOf(String name) {
    final value = name.trim();
    for (final prefix in ['https://', 'http://']) {
      if (value.toLowerCase().startsWith(prefix)) return _trimSlashes(value.substring(prefix.length));
    }
    return value;
  }

  static String _trimSlashes(String value) => value.replaceAll(RegExp(r'^/+|/+$'), '');

  String get canonicalAddress => BooruServer.canonicalAddressOf(baseURL);

  /// A host without its leading `www.`: every site is the same site with or without it.
  static String bareHost(String host) {
    final lowered = host.toLowerCase();
    return lowered.startsWith('www.') ? lowered.substring(4) : lowered;
  }

  /// Stable across devices: the same site entered with or without `https`, `www.`, a
  /// default port, a query or `index.php` is one server.
  static String canonicalAddressOf(String url) {
    final parts = SwiftURLComponents.parse(url);
    if (parts == null) return url;
    parts.scheme = 'https';
    parts.host = bareHost(parts.host ?? '');
    if (parts.port == 443) parts.port = null;
    parts.query = null;
    parts.fragment = null;
    if (parts.path.endsWith('/index.php')) parts.path = parts.path.substring(0, parts.path.length - 10);
    while (parts.path.endsWith('/')) {
      parts.path = parts.path.substring(0, parts.path.length - 1);
    }
    return parts.string;
  }

  static String validatedURL(String input) {
    final raw = input.trim();
    final parts = SwiftURLComponents.parse(raw.contains('://') ? raw : 'https://$raw');
    if (parts == null ||
        parts.scheme.toLowerCase() != 'https' ||
        (parts.host ?? '').isEmpty ||
        parts.user != null ||
        parts.password != null ||
        parts.query != null ||
        parts.fragment != null) {
      throw const BooruError(BooruErrorKind.invalidServer);
    }
    parts.scheme = 'https';
    parts.host = parts.host!.toLowerCase();
    while (parts.path.endsWith('/')) {
      parts.path = parts.path.substring(0, parts.path.length - 1);
    }
    if (parts.path.endsWith('/index.php')) parts.path = parts.path.substring(0, parts.path.length - 10);
    return parts.string;
  }

  /// Decoding legacy server metadata; never generates search tags. The native app also counts
  /// one named website here. Without names, a server that reports a modern rating word is
  /// recognized from its responses instead ([BooruClient] passes that to the decoder).
  bool get usesModernRatings => engine == BooruEngine.danbooru;

  String pageURL(int postID) => switch (engine) {
    BooruEngine.danbooru => _appending('posts/$postID'),
    BooruEngine.moebooru => _appending('post/show/$postID'),
    BooruEngine.gelbooru || BooruEngine.oldGelbooru => '${_appending('index.php')}?${booruQuery([('page', 'post'), ('s', 'view'), ('id', '$postID')])}',
  };

  String browsingURL(String query, {int? poolID}) {
    switch (engine) {
      case BooruEngine.danbooru:
        return poolID == null ? '$baseURL/posts?${booruQuery([('tags', query)])}' : '$baseURL/pools/$poolID';
      case BooruEngine.moebooru:
        return poolID == null ? '$baseURL/post?${booruQuery([('tags', query)])}' : '$baseURL/pool/show/$poolID';
      case BooruEngine.gelbooru || BooruEngine.oldGelbooru:
        final items = [('page', poolID == null ? 'post' : 'pool'), ('s', poolID == null ? 'list' : 'show')];
        if (poolID != null) {
          items.add(('id', '$poolID'));
        } else if (query.isNotEmpty) {
          items.add(('tags', query));
        }
        return '$baseURL/index.php?${booruQuery(items)}';
    }
  }

  /// `baseURL.appendingPathComponent(path)`.
  String _appending(String path) => baseURL.endsWith('/') ? '$baseURL$path' : '$baseURL/$path';

  factory BooruServer.fromJson(JsonObject json) =>
      BooruServer(id: json.string('id'), name: json.string('name'), baseURL: json.string('baseURL'), engine: BooruEngine.fromRawValue(json.string('engine')));

  JsonObject toJson() => {'id': id, 'name': name, 'baseURL': baseURL, 'engine': engine.rawValue};

  @override
  bool operator ==(Object other) => other is BooruServer && other.id == id && other.name == name && other.baseURL == baseURL && other.engine == engine;

  @override
  int get hashCode => Object.hash(id, name, baseURL, engine);
}

class BooruCredentials {
  const BooruCredentials({this.account = '', this.apiKey = ''});
  final String account;
  final String apiKey;
  bool get isEmpty => account.isEmpty && apiKey.isEmpty;
}

class BooruPost {
  BooruPost({
    required this.serverID,
    required this.postID,
    this.previewURL,
    this.sampleURL,
    this.fileURL,
    required this.width,
    required this.height,
    required this.tags,
    required this.artists,
    required this.rating,
    required this.score,
    required this.fileExtension,
    this.poolIDs = const [],
    this.metadataTags,
    this.favoriteCount,
    this.upvoteCount,
    this.commentCount,
    this.reducedDataURL,
    this.tagCategories,
    this.animated,
    this.animationVideoURL,
    this.isDeleted,
    this.isBanned,
  });

  final String serverID;
  final int postID;
  String? previewURL;
  String? sampleURL;
  String? fileURL;
  int width;
  int height;
  List<String> tags;
  List<String> artists;
  String rating;
  int score;
  String fileExtension;
  List<int> poolIDs;
  List<String>? metadataTags;
  int? favoriteCount;
  int? upvoteCount;
  int? commentCount;
  String? reducedDataURL;
  Map<String, int>? tagCategories;
  bool? animated;
  String? animationVideoURL;
  bool? isDeleted;
  bool? isBanned;

  bool get isRemoved => isDeleted == true || isBanned == true;
  String get id => '$serverID:$postID';

  static const videoExtensions = ['mp4', 'webm', 'mov', 'm4v'];
  bool get isUgoira => fileExtension.toLowerCase() == 'zip';
  String? get animationPlaybackURL =>
      animationVideoURL ?? [sampleURL, reducedDataURL].nonNulls.where((url) => videoExtensions.contains(urlPathExtension(url).toLowerCase())).firstOrNull;
  bool get isVideo => videoExtensions.contains(fileExtension.toLowerCase()) || isUgoira && animationPlaybackURL != null;
  bool get isAnimated => isUgoira || tags.contains('animated') || (animated ?? ['gif', 'webp', 'apng'].contains(fileExtension.toLowerCase()));
  String? get displayURL => sampleURL ?? fileURL ?? previewURL;

  /// A preview-only post must resolve its details before entering the viewer.
  String? viewerURL({required bool original, bool reducedData = false}) {
    // A ZIP contains animation frames, not a browser-decodable image. Keep
    // the original for downloads and use the site's video conversion to view.
    if (isUgoira) return animationPlaybackURL;
    if (isVideo || isAnimated || original) return fileURL ?? sampleURL;
    if (reducedData) return reducedDataURL ?? sampleURL ?? fileURL;
    return sampleURL ?? fileURL;
  }

  BooruPost copy() => BooruPost.fromJson(toJson());

  factory BooruPost.fromJson(JsonObject json) => BooruPost(
    serverID: json.string('serverID'),
    postID: json.integer('postID'),
    previewURL: _url(json, 'previewURL'),
    sampleURL: _url(json, 'sampleURL'),
    fileURL: _url(json, 'fileURL'),
    width: json.integer('width'),
    height: json.integer('height'),
    tags: json.strings('tags'),
    artists: json.strings('artists'),
    rating: json.string('rating'),
    score: json.integer('score'),
    fileExtension: json.string('fileExtension'),
    poolIDs: json.list('poolIDs', jsonInteger),
    metadataTags: json.stringsOrNull('metadataTags'),
    favoriteCount: json.integerOrNull('favoriteCount'),
    upvoteCount: json.integerOrNull('upvoteCount'),
    commentCount: json.integerOrNull('commentCount'),
    reducedDataURL: _url(json, 'reducedDataURL'),
    tagCategories: json.dictionaryOrNull('tagCategories', jsonInteger),
    animated: json.booleanOrNull('animated'),
    animationVideoURL: _url(json, 'animationVideoURL'),
    isDeleted: json.booleanOrNull('isDeleted'),
    isBanned: json.booleanOrNull('isBanned'),
  );

  /// `URL` decoding fails for a string `URL(string:)` cannot read.
  static String? _url(JsonObject json, String key) {
    final value = json.stringOrNull(key);
    if (value != null && SwiftURLComponents.parse(value) == null) throw SwiftJsonError('Invalid URL for "$key"');
    return value;
  }

  JsonObject toJson() =>
      <String, Object?>{
          'serverID': serverID,
          'postID': postID,
          'width': width,
          'height': height,
          'tags': tags,
          'artists': artists,
          'rating': rating,
          'score': score,
          'fileExtension': fileExtension,
          'poolIDs': poolIDs,
        }
        ..putIfPresent('previewURL', previewURL)
        ..putIfPresent('sampleURL', sampleURL)
        ..putIfPresent('fileURL', fileURL)
        ..putIfPresent('metadataTags', metadataTags)
        ..putIfPresent('favoriteCount', favoriteCount)
        ..putIfPresent('upvoteCount', upvoteCount)
        ..putIfPresent('commentCount', commentCount)
        ..putIfPresent('reducedDataURL', reducedDataURL)
        ..putIfPresent('tagCategories', tagCategories)
        ..putIfPresent('animated', animated)
        ..putIfPresent('animationVideoURL', animationVideoURL)
        ..putIfPresent('isDeleted', isDeleted)
        ..putIfPresent('isBanned', isBanned);

  /// The same post filed under another server ID. Like the native copy, it
  /// leaves out the reduced, category, animation and video fields.
  BooruPost onServer(String id) => BooruPost(
    serverID: id,
    postID: postID,
    previewURL: previewURL,
    sampleURL: sampleURL,
    fileURL: fileURL,
    width: width,
    height: height,
    tags: tags,
    artists: artists,
    rating: rating,
    score: score,
    fileExtension: fileExtension,
    poolIDs: poolIDs,
    metadataTags: metadataTags,
    favoriteCount: favoriteCount,
    upvoteCount: upvoteCount,
    commentCount: commentCount,
    isDeleted: isDeleted,
    isBanned: isBanned,
  );

  /// Imported embedded thumbnails or device-local paths must never become cloud media.
  BooruPost get cloudMetadata {
    String? remote(String? url) => isRemoteURL(url) ? url : null;
    return BooruPost.fromJson(toJson())
      ..previewURL = remote(previewURL)
      ..sampleURL = remote(sampleURL)
      ..fileURL = remote(fileURL);
  }
}

/// Each line is an OR rule; space-separated terms within a line are ANDed.
/// A leading minus negates a term. Wildcards and rating: terms work offline too.
class BooruBlacklist {
  BooruBlacklist(String text)
    : rules = text
          .split(RegExp(r'\r\n|[\n\r\u000B\u000C\u0085  ]'))
          .map((line) => splitWhitespace(line.toLowerCase()))
          .where((rule) => rule.isNotEmpty && !rule[0].startsWith('#'))
          .toList();

  final List<List<String>> rules;

  bool contains(BooruPost post) {
    if (rules.isEmpty) return false;
    final tags = post.tags.map((tag) => tag.toLowerCase()).toSet();
    return rules.any(
      (rule) => rule.every((term) {
        final negative = term.startsWith('-');
        final value = negative ? term.substring(1) : term;
        final bool matches;
        if (value.startsWith('rating:')) {
          matches = _rating(value.substring(7)) == _rating(post.rating);
        } else if (value.startsWith('artist:')) {
          matches = post.artists.any((artist) => artist.toLowerCase() == value.substring(7));
        } else if (value.startsWith('id:')) {
          matches = '${post.postID}' == value.substring(3);
        } else if (value.contains('*')) {
          final pattern = RegExp('^${value.split('*').map(RegExp.escape).join('.*')}\$');
          matches = tags.any(pattern.hasMatch);
        } else {
          matches = tags.contains(value);
        }
        return negative ? !matches : matches;
      }),
    );
  }

  static String _rating(String value) => switch (value) {
    'g' || 'general' || 'safe' => 'g',
    's' || 'sensitive' => 's',
    'q' || 'questionable' => 'q',
    'e' || 'explicit' => 'e',
    _ => value,
  };
}

enum BooruErrorKind { validationRequired, invalidServer, invalidResponse, authentication, rateLimited, unavailable, unsupported, duplicateServer, storage }

class BooruError implements Exception {
  const BooruError(this.kind, [this.status]);
  final BooruErrorKind kind;
  final int? status;

  String get errorDescription => switch (kind) {
    BooruErrorKind.validationRequired => L10n.text('The server requested browser verification. Use Validate Client and complete the check, then retry.'),
    BooruErrorKind.invalidServer => L10n.text('Enter an HTTPS server address without a query or credentials.'),
    BooruErrorKind.invalidResponse => L10n.text('The server returned an unsupported response. Check the server type and address.'),
    BooruErrorKind.authentication => L10n.text('This server requires access. Check your account and API key in Servers.'),
    BooruErrorKind.rateLimited => L10n.text('The server is busy. Wait a moment before trying again.'),
    BooruErrorKind.unavailable => L10n.text('Server error (%@). Please try again.', ['$status']),
    BooruErrorKind.unsupported => L10n.text('This server does not expose this feature.'),
    BooruErrorKind.duplicateServer => L10n.text('This server address is already configured.'),
    BooruErrorKind.storage => L10n.text('Unable to save. Please try again.'),
  };

  @override
  String toString() => 'BooruError.${kind.name}';
}

class BooruFolder {
  BooruFolder({required this.id, required this.name, required this.color, this.isSmart = false});
  final String id;
  String name;
  int color;
  bool isSmart;

  String get plainName => id == 'unsorted' ? L10n.text('Uncategorized') : BooruServer.displayNameOf(name);
  String get displayName => FolderRule.markedName(plainName, isSmart: isSmart);
}

/// `url.pathExtension`: the last path component's extension, without the dot.
String urlPathExtension(String? url) {
  if (url == null) return '';
  var path = url;
  final end = path.indexOf(RegExp('[?#]'));
  if (end >= 0) path = path.substring(0, end);
  final scheme = path.indexOf('://');
  if (scheme >= 0) {
    final slash = path.indexOf('/', scheme + 3);
    path = slash < 0 ? '' : path.substring(slash);
  }
  while (path.endsWith('/')) {
    path = path.substring(0, path.length - 1);
  }
  final name = path.substring(path.lastIndexOf('/') + 1);
  final dot = name.lastIndexOf('.');
  return dot <= 0 || dot == name.length - 1 ? '' : name.substring(dot + 1);
}

/// `URLComponents.queryItems` encoding: query characters stay, separators and spaces are escaped.
String booruQuery(List<(String, String)> items) => items.map((item) => '${_queryComponent(item.$1)}=${_queryComponent(item.$2)}').join('&');

String _queryComponent(String value) {
  final buffer = StringBuffer();
  for (final byte in utf8.encode(value)) {
    final character = String.fromCharCode(byte);
    if (byte < 128 && RegExp(r"[A-Za-z0-9\-._~!$'()*,;:@/?\[\]]").hasMatch(character)) {
      buffer.write(character);
    } else {
      buffer.write('%${byte.toRadixString(16).toUpperCase().padLeft(2, '0')}');
    }
  }
  return buffer.toString();
}

/// `URLComponents(string:)?.queryItems` of a link: names and percent-decoded values, or null for a link it cannot read.
List<(String, String?)>? linkQueryItems(String href) {
  if (!RegExp(r"^[A-Za-z0-9\-._~:/?#\[\]@!$&'()*+,;=%]*$").hasMatch(href)) return null;
  var rest = href;
  final hash = rest.indexOf('#');
  if (hash >= 0) rest = rest.substring(0, hash);
  final mark = rest.indexOf('?');
  if (mark < 0) return [];
  final query = rest.substring(mark + 1);
  if (query.isEmpty) return [];
  String decode(String value) {
    try {
      return Uri.decodeComponent(value);
    } on ArgumentError {
      return value;
    }
  }

  return [
    for (final part in query.split('&'))
      if (part.contains('=')) (decode(part.substring(0, part.indexOf('='))), decode(part.substring(part.indexOf('=') + 1))) else (decode(part), null),
  ];
}

String? linkQueryValue(List<(String, String?)>? items, String name) => items?.where((item) => item.$1 == name).firstOrNull?.$2;

class BooruTag {
  const BooruTag({required this.name, required this.count, required this.category, this.isMetadata = false});
  final String name;
  final int count;
  final int category;
  final bool isMetadata;
  String get id => name;
  bool get isArtist => category == 1;

  @override
  bool operator ==(Object other) =>
      other is BooruTag && other.name == name && other.count == count && other.category == category && other.isMetadata == isMetadata;
  @override
  int get hashCode => Object.hash(name, count, category, isMetadata);
  @override
  String toString() => 'BooruTag($name, $count, $category)';
}

class BooruPool {
  BooruPool({required this.id, required this.name, required this.count, this.description = '', this.hasKnownCount = false});
  final int id;
  String name;
  int count;
  String description;
  bool hasKnownCount;

  @override
  bool operator ==(Object other) =>
      other is BooruPool &&
      other.id == id &&
      other.name == name &&
      other.count == count &&
      other.description == description &&
      other.hasKnownCount == hasKnownCount;
  @override
  int get hashCode => Object.hash(id, name, count, description, hasKnownCount);
  @override
  String toString() => 'BooruPool($id, $name, $count)';
}

class BooruNote {
  const BooruNote({required this.id, required this.x, required this.y, required this.width, required this.height, required this.body});
  final int id;
  final double x;
  final double y;
  final double width;
  final double height;
  final String body;

  @override
  bool operator ==(Object other) =>
      other is BooruNote && other.id == id && other.x == x && other.y == y && other.width == width && other.height == height && other.body == body;
  @override
  int get hashCode => Object.hash(id, x, y, width, height, body);
}

class BooruBatch {
  const BooruBatch({required this.posts, required this.hasMore, this.goldRestrictedIDs = const []});
  final List<BooruPost> posts;
  final bool hasMore;
  final List<int> goldRestrictedIDs;
  int get sourcePostCount => posts.length + goldRestrictedIDs.length;
}

enum BooruSort {
  latest,
  popular,
  trending,
  mostFavorited,
  mostUpvoted,
  mostDiscussed,
  popularWeek,
  popularMonth;

  String get rawValue => name;
  String get id => name;

  String get title => switch (this) {
    latest => L10n.text('Latest'),
    popular => L10n.text('Popular · Score'),
    trending => L10n.text('Popular · Trending'),
    mostFavorited => L10n.text('Popular · Favorites'),
    mostUpvoted => L10n.text('Popular · Upvotes'),
    mostDiscussed => L10n.text('Popular · Comments'),
    popularWeek => L10n.text('Popular · Past 7 Days'),
    popularMonth => L10n.text('Popular · Past 30 Days'),
  };

  static List<BooruSort> optionsFor(BooruEngine engine) => switch (engine) {
    BooruEngine.danbooru => values,
    BooruEngine.moebooru => const [latest, popular, popularWeek, popularMonth],
    BooruEngine.gelbooru || BooruEngine.oldGelbooru => const [latest, popular],
  };

  static List<BooruSort> options(List<BooruServer> servers, {bool local = false}) {
    if (local || servers.isEmpty) return const [latest, popular];
    return values.where((option) => servers.every((server) => optionsFor(server.engine).contains(option))).toList();
  }

  bool get restrictsPeriod => this == trending || this == popularWeek || this == popularMonth;

  int? metric(BooruPost post) => switch (this) {
    popular || popularWeek || popularMonth => post.score,
    mostFavorited => post.favoriteCount,
    mostUpvoted => post.upvoteCount,
    mostDiscussed => post.commentCount,
    _ => null,
  };

  String query(String query, BooruEngine engine, {DateTime? now}) {
    if (this == latest || !optionsFor(engine).contains(this)) return query;
    final terms = splitWhitespace(query).where((term) => !term.toLowerCase().startsWith('order:') && !term.toLowerCase().startsWith('sort:')).toList();
    if (this == popularWeek || this == popularMonth) {
      // This restriction is explicit in the selected menu label. Preserve
      // user date constraints instead of silently widening their query.
      if (!terms.any((term) => term.startsWith('date:') || term.startsWith('age:'))) {
        final days = this == popularWeek ? 7 : 30;
        final date = (now ?? DateTime.now()).toUtc().subtract(Duration(days: days));
        String two(int value) => value.toString().padLeft(2, '0');
        terms.add('date:>=${date.year.toString().padLeft(4, '0')}-${two(date.month)}-${two(date.day)}');
      }
    }
    final order = switch (this) {
      trending => 'rank',
      mostFavorited => 'favcount',
      mostUpvoted => 'upvotes',
      mostDiscussed => 'comment_count',
      _ => 'score',
    };
    terms.add(engine == BooruEngine.gelbooru ? 'sort:score:desc' : 'order:$order');
    return terms.join(' ');
  }
}

class BooruCompletion {
  BooruCompletion._(this.prefix, this.token, this.negative);

  final String prefix;
  final String token;
  final bool negative;

  static BooruCompletion? parse(String text) {
    if (text.isEmpty || isWhitespace(text[text.length - 1])) return null;
    var start = 0;
    for (var index = text.length - 1; index >= 0; index--) {
      if (isWhitespace(text[index])) {
        start = index + 1;
        break;
      }
    }
    final word = text.substring(start);
    final negative = word.startsWith('-');
    final token = (negative ? word.substring(1) : word).toLowerCase();
    if (token.isEmpty || token.contains(':')) return null;
    return BooruCompletion._(text.substring(0, start), token, negative);
  }

  String inserting(String name) => '$prefix${negative ? '-' : ''}$name ';

  @override
  bool operator ==(Object other) => other is BooruCompletion && other.prefix == prefix && other.token == token && other.negative == negative;
  @override
  int get hashCode => Object.hash(prefix, token, negative);
}

/// An optional default search condition, not a content restriction.
enum BooruSafeRating {
  general('g'),
  sensitive('s'),
  questionable('q');

  const BooruSafeRating(this.rawValue);
  final String rawValue;

  static BooruSafeRating? fromRawValue(String? value) => values.where((rating) => rating.rawValue == value).firstOrNull;

  String get id => rawValue;
  String get tag => 'rating:$rawValue';
  String get title => switch (this) {
    general => L10n.text('All Ages'),
    sensitive => '12+',
    questionable => '15+',
  };

  String applyingDefault(String query) {
    // An explicitly entered rating overrides this optional default.
    final hasRating = splitWhitespace(query).any((term) => term.replaceAll(RegExp(r'^[-~]+|[-~]+$'), '').toLowerCase().startsWith('rating:'));
    if (hasRating) return query;
    return query.isEmpty ? tag : '$query $tag';
  }
}
