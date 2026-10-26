import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:tegnal/core/app_controller.dart';
import 'package:tegnal/core/content.dart';
import 'package:tegnal/core/library.dart';
import 'package:tegnal/data/library_store.dart';
import 'package:tegnal/data/download_manager.dart';

/// Screenshot-only content. This never opens the application's on-disk store.
class CaptureFixtures {
  CaptureFixtures(this.marketingDirectory);

  final Directory marketingDirectory;
  final images = <String, Uint8List>{};
  final items = <ContentItem>[];
  final mangaItems = <ContentItem>[];
  final store = LibraryStore.memory();
  static const sourceId = 'ui-capture-source';
  static const mangaSourceId = 'ui-capture-manga-source';

  Future<AppController> load() async {
    final manifest = jsonDecode(
      await File('${marketingDirectory.path}/asset-manifest.json')
          .readAsString(),
    ) as List;
    final nativeSeed = jsonDecode(
      await File('${marketingDirectory.path}/marketing-library.json')
          .readAsString(),
    ) as Map;
    for (final (position, dynamic folder)
        in (nativeSeed['folders'] as List).indexed) {
      if (folder['id'] == 'unsorted') continue;
      store.saveFolder(
        LibraryFolder(
          id: folder['id'] as String,
          mode: AppMode.booru,
          name: folder['name'] as String,
          color: folder['color'] as int,
          position: position,
        ),
      );
    }
    final mangaFolder = LibraryFolder(
      id: 'ui-capture-manga-folder',
      mode: AppMode.manga,
      name: 'Manga Works',
      color: 0xFF5E5CE6,
      position: 0,
    );
    store.saveFolder(mangaFolder);
    final previewUris = <Uri>[
      for (final (index, dynamic record) in manifest.indexed)
        if (File(
              '${marketingDirectory.path}/${(record as Map)['file']}',
            ).lengthSync() <=
            2 * 1024 * 1024)
          Uri.https('ui-capture.invalid', '/image/$index.png'),
    ];
    if (previewUris.isEmpty) {
      throw StateError('Capture requires at least one bounded local preview.');
    }
    for (final (index, dynamic record) in manifest.indexed) {
      final entry = Map<String, dynamic>.from(record as Map);
      final folderId = entry['folder_id'] as String;
      final uri = Uri.https('ui-capture.invalid', '/image/$index.png');
      final imageBytes = await File(
        '${marketingDirectory.path}/${entry['file']}',
      ).readAsBytes();
      images[uri.path] = imageBytes;
      final item = ContentItem(
        sourceId: sourceId,
        id: index + 1,
        mode: AppMode.booru,
        title: '${entry['folder_name']} ${index % 4 + 1}',
        thumbnailUrl: previewUris[index % previewUris.length],
        mediaUrl: uri,
        pageUrl: Uri.https('ui-capture.invalid', '/posts/${index + 1}'),
        width: entry['width'] as int,
        height: entry['height'] as int,
        tags: [
          'scenery',
          'original',
          'no_humans',
          ['sky', 'flowers', 'landscape', 'still_life'][index % 4],
        ],
        artists: [
          ['studio_sora', 'mori', 'aoi', 'suzume'][index % 4],
        ],
        score: 120 - index,
      );
      items.add(item);
      store.saveItem(
        item,
        folderIds: folderId == 'unsorted' ? [] : [folderId],
        savedAt: DateTime.utc(2026, 10, 1).subtract(Duration(minutes: index)),
      );
    }
    for (var index = 0; index < 4; index++) {
      final id = 100001 + index;
      final imageUri = previewUris[index % previewUris.length];
      final item = ContentItem(
        sourceId: mangaSourceId,
        id: id,
        mode: AppMode.manga,
        title: [
          'A quiet afternoon',
          'Across the garden',
          'Blue window',
          'Spring notes',
        ][index],
        thumbnailUrl: imageUri,
        mediaUrl: imageUri,
        pageUrl: Uri.https('ui-capture.invalid', '/galleries/$id'),
        tags: ['original', 'scenery', 'group:studio_sora'],
        artists: ['studio_sora'],
        pageCount: 12,
        metadata: {'fixture': true},
      );
      mangaItems.add(item);
      store.saveItem(
        item,
        folderIds: index < 2 ? [mangaFolder.id] : [],
        savedAt: DateTime.utc(2026, 9, 20).subtract(Duration(days: index)),
        note: index == 0 ? 'A locally saved note for capture.' : '',
      );
    }
    store.saveSource(
      SourceConfig(
        id: sourceId,
        name: 'Danbooru',
        baseUrl: Uri.https('ui-capture.invalid'),
        kind: SourceKind.danbooru,
      ),
    );
    store.saveSource(
      SourceConfig(
        id: mangaSourceId,
        name: 'Local manga fixture',
        baseUrl: Uri.https('ui-capture.invalid'),
        kind: SourceKind.manga,
      ),
    );
    for (final name in ['studio_sora', 'mori', 'aoi', 'suzume']) {
      store.saveArtist(
        ArtistEntry(name: name, mode: AppMode.booru, sourceId: sourceId),
      );
    }
    for (final name in ['scenery', 'flowers', 'sky']) {
      store.saveArtist(
        ArtistEntry(
          name: name,
          mode: AppMode.booru,
          sourceId: sourceId,
          kind: 1,
        ),
      );
    }
    for (final (index, query) in [
      'original scenery',
      'flowers sky',
      'landscape sunset',
      'still_life',
    ].indexed) {
      store.recordSearch(
        AppMode.booru,
        sourceId,
        query,
        usedAt: DateTime.utc(2026, 10, 10 + index),
      );
    }
    store.setPortable('backup.images', {
      'savedTags': [
        for (final name in [
          'original scenery',
          'flowers sky',
          'landscape sunset',
        ])
          {'kind': 'search', 'name': name, 'serverID': sourceId},
      ],
    });
    store.setSetting('onboarding', true);
    store.setSetting('onboarding.importReminderDismissed', true);
    store.setSetting('mode', 'booru');
    store.setSetting('appearance', 'dark');
    store.setSetting('language', 'ko');
    store.setSetting('selected.booru', [sourceId]);
    store.setSetting('source.manga', mangaSourceId);
    final controller = AppController(
      store,
      sourceFactory: (_) => _OfflineSource([...items, ...mangaItems]),
    );
    controller.explore().items = List.of(items);
    controller.explore().page = 1;
    return controller;
  }
}

/// A screenshot session supplies image pages directly, avoiding optional notes
/// and native downloader I/O while retaining the real detail/reader widgets.
class CaptureDownloads extends DownloadManager {
  CaptureDownloads(super.store, super.directory);
  @override
  Future<List<ReaderPage>?> offlinePages(ContentItem item) async => [
    for (var index = 0; index < (item.mode == AppMode.manga ? 8 : 1); index++)
      ReaderPage(
        url: item.mode == AppMode.manga
            ? Uri.https(
                'ui-capture.invalid',
                '/image/${(item.id + index) % 24}.png',
              )
            : item.mediaUrl!,
        thumbnailUrl: item.mode == AppMode.manga
            ? item.thumbnailUrl ?? item.mediaUrl
            : item.mediaUrl,
        width: item.width,
        height: item.height,
      ),
  ];
}

class _OfflineSource implements ContentSource {
  _OfflineSource(this.items);
  final List<ContentItem> items;
  @override
  Future<ContentPage> search(
    String query, {
    int page = 1,
    bool popular = false,
  }) async => ContentPage(items, hasMore: false);
  @override
  Future<ContentItem> detail(int id) async =>
      items.firstWhere((i) => i.id == id);
  @override
  Future<List<ReaderPage>> pages(ContentItem item) async => [
    for (var index = 0; index < (item.mode == AppMode.manga ? 8 : 1); index++)
      ReaderPage(
        url: Uri.https(
          'ui-capture.invalid',
          '/image/${(item.id + index) % 24}.png',
        ),
        thumbnailUrl: item.thumbnailUrl ?? item.mediaUrl,
        width: item.width,
        height: item.height,
      ),
  ];
  @override
  Future<List<String>> suggestions(String query) async => [];
  @override
  void close() {}
}

/// Only .invalid fixture URLs resolve; unexpected network requests fail loudly.
class CaptureHttpOverrides extends HttpOverrides {
  CaptureHttpOverrides(this.images);
  final Map<String, Uint8List> images;
  final unexpectedRequests = <Uri>[];
  int imageRequests = 0;
  int imageResponsesCompleted = 0;
  @override
  HttpClient createHttpClient(SecurityContext? context) =>
      _FixtureClient(
        images,
        unexpectedRequests,
        onRequest: () => imageRequests++,
        onResponseComplete: () => imageResponsesCompleted++,
      );
}

class _FixtureClient extends Fake implements HttpClient {
  _FixtureClient(
    this.images,
    this.unexpectedRequests, {
    required this.onRequest,
    required this.onResponseComplete,
  });
  final Map<String, Uint8List> images;
  final List<Uri> unexpectedRequests;
  final void Function() onRequest;
  final void Function() onResponseComplete;
  bool _autoUncompress = true;
  @override
  bool get autoUncompress => _autoUncompress;
  @override
  set autoUncompress(bool value) => _autoUncompress = value;
  @override
  Future<HttpClientRequest> openUrl(String method, Uri url) async {
    if (url.host != 'ui-capture.invalid' || !images.containsKey(url.path)) {
      unexpectedRequests.add(url);
      throw StateError(
        'Screenshot attempted an unexpected network request: $url',
      );
    }
    onRequest();
    return _FixtureRequest(
      method,
      url,
      images[url.path]!,
      onResponseComplete,
    );
  }
  @override
  Future<HttpClientRequest> getUrl(Uri url) => openUrl('GET', url);
  @override
  void close({bool force = false}) {}
}

class _FixtureRequest extends Fake implements HttpClientRequest {
  _FixtureRequest(this.method, this.uri, this.bytes, this.onResponseComplete);
  @override
  final String method;
  @override
  final Uri uri;
  final Uint8List bytes;
  final void Function() onResponseComplete;
  final _FixtureHeaders _headers = _FixtureHeaders();
  final BytesBuilder _body = BytesBuilder(copy: false);
  int _contentLength = -1;
  bool _followRedirects = true;
  int _maxRedirects = 5;
  bool _persistentConnection = true;
  bool _bufferOutput = true;
  @override
  HttpHeaders get headers => _headers;
  @override
  int get contentLength => _contentLength;
  @override
  set contentLength(int value) => _contentLength = value;
  @override
  bool get followRedirects => _followRedirects;
  @override
  set followRedirects(bool value) => _followRedirects = value;
  @override
  int get maxRedirects => _maxRedirects;
  @override
  set maxRedirects(int value) => _maxRedirects = value;
  @override
  bool get persistentConnection => _persistentConnection;
  @override
  set persistentConnection(bool value) => _persistentConnection = value;
  @override
  bool get bufferOutput => _bufferOutput;
  @override
  set bufferOutput(bool value) => _bufferOutput = value;
  @override
  void add(List<int> data) => _body.add(data);
  @override
  Future<void> addStream(Stream<List<int>> stream) async {
    await for (final chunk in stream) {
      _body.add(chunk);
    }
  }
  @override
  Future<HttpClientResponse> close() async =>
      _FixtureResponse(bytes, onResponseComplete);
}

class _FixtureHeaders extends Fake implements HttpHeaders {
  final Map<String, List<String>> _values = {};
  @override
  void add(String name, Object value, {bool preserveHeaderCase = false}) {
    _values.putIfAbsent(name.toLowerCase(), () => []).add('$value');
  }
  @override
  void set(String name, Object value, {bool preserveHeaderCase = false}) {
    _values[name.toLowerCase()] = ['$value'];
  }
  @override
  void remove(String name, Object value) {
    _values[name.toLowerCase()]?.remove('$value');
  }
  @override
  void removeAll(String name) => _values.remove(name.toLowerCase());
  @override
  String? value(String name) => _values[name.toLowerCase()]?.first;
  @override
  List<String>? operator [](String name) => _values[name.toLowerCase()];
  @override
  void forEach(void Function(String name, List<String> values) action) {
    _values.forEach(action);
  }
  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

class _FixtureResponse extends Stream<List<int>> implements HttpClientResponse {
  _FixtureResponse(this.bytes, this.onComplete);
  final Uint8List bytes;
  final void Function() onComplete;
  @override
  int get statusCode => HttpStatus.ok;
  @override
  int get contentLength => bytes.length;
  @override
  String get reasonPhrase => 'OK';
  @override
  HttpHeaders get headers => _FixtureHeaders()
    ..set(HttpHeaders.contentTypeHeader, 'image/png')
    ..set(HttpHeaders.contentLengthHeader, '${bytes.length}');
  @override
  bool get isRedirect => false;
  @override
  bool get persistentConnection => false;
  @override
  List<RedirectInfo> get redirects => const [];
  @override
  HttpClientResponseCompressionState get compressionState =>
      HttpClientResponseCompressionState.notCompressed;
  @override
  StreamSubscription<List<int>> listen(
    void Function(List<int>)? onData, {
    Function? onError,
    void Function()? onDone,
    bool? cancelOnError,
  }) => Stream<List<int>>.value(bytes).listen(
    onData,
    onError: onError,
    onDone: () {
      onComplete();
      onDone?.call();
    },
    cancelOnError: cancelOnError,
  );
  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}
