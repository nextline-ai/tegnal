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

  /// Stable across devices: the same site entered with or without `https`, a
  /// default port, a query or `index.php` is one server.
  // The native app also folds `www.` for three specific hosts. That list names
  // sites, so it waits for a decision before being ported.
  static String canonicalAddressOf(String url) {
    final parts = SwiftURLComponents.parse(url);
    if (parts == null) return url;
    parts.scheme = 'https';
    parts.host = parts.host?.toLowerCase() ?? '';
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
