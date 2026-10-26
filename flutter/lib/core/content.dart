enum AppMode { manga, booru }

enum SourceKind { manga, danbooru, gelbooru, oldGelbooru, moebooru }

class SourceConfig {
  const SourceConfig({required this.id, required this.name, required this.baseUrl,
    required this.kind});
  final String id;
  final String name;
  final Uri baseUrl;
  final SourceKind kind;
  AppMode get mode => kind == SourceKind.manga ? AppMode.manga : AppMode.booru;

  static Uri validateUrl(String input) {
    final text = input.trim();
    final uri = Uri.tryParse(text.contains('://') ? text : 'https://$text');
    if (uri == null || uri.scheme != 'https' || uri.host.isEmpty ||
        uri.userInfo.isNotEmpty || uri.hasQuery || uri.hasFragment) {
      throw const FormatException('Enter an HTTPS website address without credentials, query or fragment.');
    }
    return uri.replace(path: uri.path.replaceFirst(RegExp(r'/+$'), ''));
  }

  Map<String, dynamic> toJson() => {'id': id, 'name': name,
    'baseURL': baseUrl.toString(), 'engine': kind.name};
  factory SourceConfig.fromJson(Map<String, dynamic> json) => SourceConfig(
    id: json['id'] as String, name: json['name'] as String,
    baseUrl: validateUrl(json['baseURL'] as String),
    kind: SourceKind.values.byName(json['engine'] as String));
}

/// Source-specific metadata remains available for lossless portable backups.
class ContentItem {
  const ContentItem({required this.sourceId, required this.id, required this.mode,
    required this.title, this.thumbnailUrl, this.mediaUrl, this.pageUrl,
    this.tags = const [], this.artists = const [], this.width = 0, this.height = 0,
    this.pageCount = 0, this.score = 0, this.mediaType = 'image',
    this.metadata = const {}});
  final String sourceId;
  final int id;
  final AppMode mode;
  final String title;
  final Uri? thumbnailUrl;
  final Uri? mediaUrl;
  final Uri? pageUrl;
  final List<String> tags;
  final List<String> artists;
  final int width;
  final int height;
  final int pageCount;
  final int score;
  final String mediaType;
  final Map<String, dynamic> metadata;
  String get key => '${mode.name}:$sourceId:$id';

  Map<String, dynamic> toJson() => {'sourceId': sourceId, 'id': id,
    'mode': mode.name, 'title': title, 'thumbnailUrl': thumbnailUrl?.toString(),
    'mediaUrl': mediaUrl?.toString(), 'pageUrl': pageUrl?.toString(),
    'tags': tags, 'artists': artists, 'width': width, 'height': height,
    'pageCount': pageCount, 'score': score, 'mediaType': mediaType, 'metadata': metadata};
  factory ContentItem.fromJson(Map<String, dynamic> j) => ContentItem(
    sourceId: j['sourceId'] as String, id: j['id'] as int,
    mode: AppMode.values.byName(j['mode'] as String), title: j['title'] as String,
    thumbnailUrl: _uri(j['thumbnailUrl']), mediaUrl: _uri(j['mediaUrl']),
    pageUrl: _uri(j['pageUrl']), tags: _strings(j['tags']), artists: _strings(j['artists']),
    width: j['width'] as int? ?? 0, height: j['height'] as int? ?? 0,
    pageCount: j['pageCount'] as int? ?? 0, score: j['score'] as int? ?? 0,
    mediaType: j['mediaType'] as String? ?? 'image',
    metadata: Map<String, dynamic>.from(j['metadata'] as Map? ?? {}));
  static Uri? _uri(dynamic value) => value is String ? Uri.tryParse(value) : null;
  static List<String> _strings(dynamic value) => (value as List? ?? []).cast<String>();
}

class ContentPage {
  const ContentPage(this.items, {required this.hasMore});
  final List<ContentItem> items;
  final bool hasMore;
}

class ReaderPage {
  const ReaderPage({required this.url, this.width = 0, this.height = 0,
    this.headers = const {}});
  final Uri url;
  final int width;
  final int height;
  final Map<String, String> headers;
  Map<String, dynamic> toJson() => {'url': url.toString(), 'width': width,
    'height': height, 'headers': headers};
  factory ReaderPage.fromJson(Map<String, dynamic> j) => ReaderPage(
    url: Uri.parse(j['url'] as String), width: j['width'] as int? ?? 0,
    height: j['height'] as int? ?? 0,
    headers: Map<String, String>.from(j['headers'] as Map? ?? {}));
}

abstract interface class ContentSource {
  Future<ContentPage> search(String query, {int page = 1, bool popular = false});
  Future<ContentItem> detail(int id);
  Future<List<ReaderPage>> pages(ContentItem item);
  Future<List<String>> suggestions(String query);
  void close();
}

class ContentException implements Exception {
  const ContentException(this.message, {this.statusCode});
  final String message;
  final int? statusCode;
  @override
  String toString() => message;
}
