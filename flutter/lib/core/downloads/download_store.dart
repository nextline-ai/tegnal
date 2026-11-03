import 'dart:async';
import 'dart:io';

import 'package:flutter/foundation.dart';

import '../booru/booru_models.dart';
import '../content/content_errors.dart';
import '../content/gallery_content.dart';
import '../content/manga_urls.dart';
import '../storage/app_storage.dart';
import '../support/swift_json.dart';

enum WorkDownloadMode {
  manga,
  booru;

  static WorkDownloadMode fromRawValue(String value) =>
      values.firstWhere((mode) => mode.name == value, orElse: () => throw SwiftJsonError('Unknown mode "$value"'));
}

enum WorkDownloadStatus {
  queued,
  downloading,
  paused,
  failed,
  completed;

  static WorkDownloadStatus fromRawValue(String value) =>
      values.firstWhere((status) => status.name == value, orElse: () => throw SwiftJsonError('Unknown status "$value"'));
}

/// `WorkDownload`: one downloaded work and its files, as `downloads.json` stores it.
class WorkDownload {
  WorkDownload({
    String? id,
    required this.key,
    required this.mode,
    required this.title,
    required this.origin,
    this.gallery,
    this.server,
    this.post,
    this.status = WorkDownloadStatus.queued,
    List<String>? files,
    this.bytes = 0,
    this.error,
  }) : id = id ?? uuidString(),
       files = files ?? [];

  final String id;
  final String key;
  final WorkDownloadMode mode;
  final String title;
  final String origin;
  final NativeGallery? gallery;
  final BooruServer? server;
  BooruPost? post;
  WorkDownloadStatus status;
  List<String> files;
  int bytes;
  String? error;

  int get total => gallery?.pages.length ?? 1;
  List<String> get tags => gallery?.tags ?? post?.tags ?? const [];
  List<String> get artists => gallery?.artists ?? post?.artists ?? const [];

  /// Match every word across local metadata. Underscores and spaces are
  /// equivalent, so tags copied from a booru work with ordinary typing too.
  bool matches(String query) {
    final metadata = _normalized(
      [
        title,
        origin,
        gallery?.language ?? '',
        gallery?.type ?? '',
        gallery != null ? '${gallery!.id}' : (post != null ? '${post!.postID}' : ''),
        ...tags,
        ...artists,
      ].join(' '),
    );
    return splitWhitespace(_normalized(query)).every(metadata.contains);
  }

  static String _normalized(String text) => foldDiacritics(text.replaceAll('_', ' ').toLowerCase());

  factory WorkDownload.fromJson(JsonObject json) => WorkDownload(
    id: json.string('id'),
    key: json.string('key'),
    mode: WorkDownloadMode.fromRawValue(json.string('mode')),
    title: json.string('title'),
    origin: json.string('origin'),
    gallery: switch (json.objectOrNull('gallery')) {
      final value? => NativeGallery.fromJson(value),
      null => null,
    },
    server: switch (json.objectOrNull('server')) {
      final value? => BooruServer.fromJson(value),
      null => null,
    },
    post: switch (json.objectOrNull('post')) {
      final value? => BooruPost.fromJson(value),
      null => null,
    },
    status: WorkDownloadStatus.fromRawValue(json.string('status')),
    files: json.strings('files'),
    bytes: json.integer('bytes'),
    error: json.stringOrNull('error'),
  );

  JsonObject toJson() => <String, Object?>{'id': id, 'key': key, 'mode': mode.name, 'title': title, 'origin': origin}
    ..putIfPresent('gallery', gallery?.toJson())
    ..putIfPresent('server', server?.toJson())
    ..putIfPresent('post', post?.toJson())
    ..addAll({'status': status.name, 'files': files, 'bytes': bytes})
    ..putIfPresent('error', error);
}

/// `String.folding(options: [.caseInsensitive, .diacriticInsensitive])` for the Latin
/// letters people type in titles and tags; other scripts have no marks to fold here.
String foldDiacritics(String text) {
  final buffer = StringBuffer();
  for (final rune in text.runes) {
    buffer.write(_folded[rune] ?? String.fromCharCode(rune));
  }
  return buffer.toString();
}

final Map<int, String> _folded = () {
  const groups = {
    'a': 'àáâãäåāăą',
    'c': 'çćĉċč',
    'd': 'ďđ',
    'e': 'èéêëēĕėęě',
    'g': 'ĝğġģ',
    'h': 'ĥħ',
    'i': 'ìíîïĩīĭįı',
    'j': 'ĵ',
    'k': 'ķ',
    'l': 'ĺļľŀł',
    'n': 'ñńņňŉ',
    'o': 'òóôõöøōŏő',
    'r': 'ŕŗř',
    's': 'śŝşš',
    't': 'ţťŧ',
    'u': 'ùúûüũūŭůűų',
    'w': 'ŵ',
    'y': 'ýÿŷ',
    'z': 'źżž',
  };
  return {
    for (final MapEntry(:key, :value) in groups.entries)
      for (final rune in value.runes) rune: key,
  };
}();

/// What a booru download needs from image mode, which arrives with its own rebuild step.
abstract class BooruMediaDownloading {
  /// The post with its full file address, when a listing left it out.
  Future<BooruPost> details(BooruServer server, BooruPost post);

  /// Saves the post's media into [folder] and returns the file name, reporting progress
  /// from 0 to 1. Falls back to the signed-in browser session for images, as natively.
  Future<String> download(Uri url, {required BooruServer server, required BooruPost post, required Directory folder, void Function(double fraction)? progress});
}

class _Run {
  bool cancelled = false;
}

/// `DownloadStore`: durable downloads live outside the evictable viewer cache. One worker
/// per mode keeps large galleries from blocking image downloads or exhausting memory.
class DownloadStore extends ChangeNotifier {
  DownloadStore({required this.directory, required this.manga, this.booru, String Function()? configuredHost, this.pageDelay = const Duration(seconds: 1)})
    : _configuredHost = configuredHost ?? (() => MangaUrls.configuredHost) {
    try {
      directory.createSync(recursive: true);
      // The native store excludes this folder from device backups; the Android backup
      // rules leave the app's support directory out instead.
      final manifest = File('${directory.path}/downloads.json');
      if (manifest.existsSync()) {
        final values = decodeJsonValue(manifest.readAsBytesSync());
        if (values is! List) throw SwiftJsonError('Expected a list of downloads');
        items = [for (final value in values) WorkDownload.fromJson(jsonObject(value))];
        for (final item in items) {
          final files = urls(item);
          if (item.status == WorkDownloadStatus.queued ||
              item.status == WorkDownloadStatus.downloading ||
              (item.status == WorkDownloadStatus.completed && (item.files.length != item.total || files.any((file) => !file.existsSync())))) {
            item.status = WorkDownloadStatus.paused;
          }
        }
      }
    } on Object catch (error) {
      storageError = '$error';
    }
  }

  /// `Application Support/Downloads`, beside both libraries.
  static Directory get defaultDirectory => Directory('${AppStorage.container.path}/Downloads');

  final Directory directory;
  final ContentProviding manga;
  final BooruMediaDownloading? booru;
  final Duration pageDelay;
  final String Function() _configuredHost;

  List<WorkDownload> items = [];
  String? storageError;
  final Map<String, double> transferProgress = {};

  final _workers = <WorkDownloadMode, Future<void>>{};
  final _active = <WorkDownloadMode, (String, _Run)>{};
  bool _suspended = false;

  /// The run in progress for a mode, for tests.
  Future<void>? worker(WorkDownloadMode mode) => _workers[mode];

  String enqueue(NativeGallery gallery) {
    final host = _configuredHost();
    return _add(WorkDownload(key: '$host:${gallery.id}', mode: WorkDownloadMode.manga, title: gallery.title, origin: host, gallery: gallery));
  }

  String enqueuePost(BooruPost post, BooruServer server) => _add(
    WorkDownload(
      key: '${server.canonicalAddress}:${post.postID}',
      mode: WorkDownloadMode.booru,
      title: '${server.displayName} #${post.postID}',
      origin: server.canonicalAddress,
      server: server,
      post: post,
    ),
  );

  String _add(WorkDownload item) {
    final existing = items.where((other) => other.mode == item.mode && other.key == item.key).firstOrNull;
    if (existing != null) return existing.id;
    if (storageError != null) return item.id;
    items.insert(0, item);
    if (_persist()) _schedule(item.mode);
    notifyListeners();
    return item.id;
  }

  Directory folder(WorkDownload item) => Directory('${directory.path}/${item.id}');
  List<File> urls(WorkDownload item) => [for (final name in item.files) File('${folder(item).path}/$name')];

  WorkDownload? _item(String id) => items.where((item) => item.id == id).firstOrNull;

  void pause(String id) {
    final item = _item(id);
    if (item == null || (item.status != WorkDownloadStatus.queued && item.status != WorkDownloadStatus.downloading)) return;
    item.status = WorkDownloadStatus.paused;
    final active = _active[item.mode];
    if (active != null && active.$1 == id) active.$2.cancelled = true;
    _persist();
    notifyListeners();
  }

  void resume(String id) {
    final item = _item(id);
    if (item == null || (item.status != WorkDownloadStatus.failed && item.status != WorkDownloadStatus.paused)) return;
    item.status = WorkDownloadStatus.queued;
    item.error = null;
    if (_persist()) _schedule(item.mode);
    notifyListeners();
  }

  void remove(String id) {
    final item = _item(id);
    if (item == null) return;
    pause(id);
    try {
      final location = folder(item);
      if (location.existsSync()) location.deleteSync(recursive: true);
      items.removeWhere((other) => other.id == id);
      _persist();
    } on Object catch (error) {
      storageError = '$error';
    }
    notifyListeners();
  }

  /// Leaving the app pauses every running download; nothing starts until it returns.
  void setBackground(bool background) {
    _suspended = background;
    if (background) {
      for (final item in items.toList()) {
        if (item.status == WorkDownloadStatus.queued || item.status == WorkDownloadStatus.downloading) pause(item.id);
      }
    }
  }

  bool _persist() {
    try {
      final manifest = File('${directory.path}/downloads.json');
      final temporary = File('${manifest.path}.tmp');
      temporary.writeAsBytesSync(encodeSwiftJson([for (final item in items) item.toJson()]), flush: true);
      temporary.renameSync(manifest.path);
      storageError = null;
      return true;
    } on Object catch (error) {
      storageError = '$error';
      return false;
    }
  }

  void _schedule(WorkDownloadMode mode) {
    if (_suspended || _workers.containsKey(mode)) return;
    final item = items.lastWhere((item) => item.mode == mode && item.status == WorkDownloadStatus.queued, orElse: () => _none);
    if (identical(item, _none)) return;
    final run = _Run();
    _active[mode] = (item.id, run);
    _workers[mode] = () async {
      await Future<void>.value();
      await _run(item, run);
      transferProgress.remove(item.id);
      _workers.remove(mode);
      _active.remove(mode);
      notifyListeners();
      _schedule(mode);
    }();
  }

  static final _none = WorkDownload(key: '', mode: WorkDownloadMode.manga, title: '', origin: '');

  void _update(String id, _Run run, void Function(WorkDownload item) change) {
    if (run.cancelled) throw const CancellationError();
    final item = _item(id);
    if (item == null) throw const CancellationError();
    change(item);
    notifyListeners();
    if (!_persist()) throw const FileSystemException('Unable to save downloads');
  }

  Future<void> _run(WorkDownload item, _Run run) async {
    try {
      _update(item.id, run, (item) {
        item.status = WorkDownloadStatus.downloading;
        item.error = null;
      });
      folder(item).createSync(recursive: true);
      final gallery = item.gallery;
      final server = item.server, post = item.post;
      if (gallery != null) {
        // Do not silently resume a gallery against a different configured site.
        if (item.origin != _configuredHost()) throw ContentError.invalidResponse;
        for (final (index, page) in gallery.pages.indexed) {
          if (run.cancelled) throw const CancellationError();
          if (index < item.files.length && urls(item)[index].existsSync()) continue;
          final data = await manga.image(_indexed(page, index), galleryID: gallery.id, thumbnail: false);
          if (run.cancelled) throw const CancellationError();
          final ext = imageExtension(data);
          _save(data, '${'${index + 1}'.padLeft(5, '0')}.$ext', item, index, run);
          // Match the site's download pacing instead of flooding its servers.
          if (index + 1 < gallery.pages.length && pageDelay > Duration.zero) await Future<void>.delayed(pageDelay);
        }
      } else if (server != null && post != null) {
        final booru = this.booru;
        if (booru == null) throw ContentError.invalidResponse;
        final resolved = post.fileURL == null ? await booru.details(server, post) : post;
        _update(item.id, run, (item) => item.post = resolved);
        final url = resolved.fileURL == null ? null : Uri.tryParse(resolved.fileURL!);
        if (url == null || url.scheme != 'https') throw ContentError.invalidResponse;
        final name = await booru.download(
          url,
          server: server,
          post: resolved,
          folder: folder(item),
          progress: (fraction) {
            if (_active[item.mode]?.$1 != item.id) return;
            transferProgress[item.id] = fraction;
            notifyListeners();
          },
        );
        _update(item.id, run, (item) {
          item.files = [name];
          item.bytes = _fileBytes(folder(item), [name]);
        });
      } else {
        throw ContentError.invalidResponse;
      }
      _update(item.id, run, (item) => item.status = WorkDownloadStatus.completed);
    } on Object catch (error) {
      final current = _item(item.id);
      if (!run.cancelled && current != null) {
        current.status = WorkDownloadStatus.failed;
        current.error = error is ContentError ? error.errorDescription : ContentError.message(error);
        _persist();
        notifyListeners();
      }
    }
  }

  static GalleryPage _indexed(GalleryPage page, int index) => GalleryPage(
    hash: page.hash,
    name: page.name,
    width: page.width,
    height: page.height,
    hasAVIF: page.hasAVIF,
    imageURL: page.imageURL,
    thumbnailURL: page.thumbnailURL,
    index: index,
    sourceSite: page.sourceSite,
  );

  void _save(Uint8List data, String name, WorkDownload item, int index, _Run run) {
    if (run.cancelled) throw const CancellationError();
    final file = File('${folder(item).path}/$name');
    final temporary = File('${file.path}.tmp');
    temporary.writeAsBytesSync(data, flush: true);
    temporary.renameSync(file.path);
    _update(item.id, run, (item) {
      if (index < item.files.length) {
        item.files[index] = name;
      } else {
        item.files.add(name);
      }
      item.bytes = _fileBytes(folder(item), item.files);
    });
  }

  static int _fileBytes(Directory folder, List<String> names) => names.fold(0, (sum, name) {
    final file = File('${folder.path}/$name');
    return sum + (file.existsSync() ? file.lengthSync() : 0);
  });

  /// The file extension the image format prefers, read from the bytes themselves,
  /// as ImageIO names the type. Anything that is not an image is refused.
  static String imageExtension(Uint8List data) {
    bool starts(List<int> prefix, [int offset = 0]) {
      if (data.length < offset + prefix.length) return false;
      for (var index = 0; index < prefix.length; index++) {
        if (data[offset + index] != prefix[index]) return false;
      }
      return true;
    }

    if (starts([0xFF, 0xD8, 0xFF])) return 'jpeg';
    if (starts([0x89, 0x50, 0x4E, 0x47, 0x0D, 0x0A, 0x1A, 0x0A])) return 'png';
    if (starts([0x47, 0x49, 0x46, 0x38])) return 'gif';
    if (starts([0x52, 0x49, 0x46, 0x46]) && starts([0x57, 0x45, 0x42, 0x50], 8)) return 'webp';
    if (starts([0x42, 0x4D])) return 'bmp';
    if (starts([0x49, 0x49, 0x2A, 0x00]) || starts([0x4D, 0x4D, 0x00, 0x2A])) return 'tiff';
    if (starts([0x66, 0x74, 0x79, 0x70], 4) && data.length >= 12) {
      final brand = String.fromCharCodes(data.sublist(8, 12));
      if (brand == 'avif' || brand == 'avis') return 'avif';
      if (const {'heic', 'heix', 'hevc', 'hevx', 'mif1', 'msf1'}.contains(brand)) return 'heic';
    }
    throw ContentError.unsupportedFormat;
  }
}

/// `DownloadedContentSource`: reads only durable local files; never falls back to the
/// network or the viewer cache.
class DownloadedContentSource extends ContentProviding {
  DownloadedContentSource({required this.item, required this.folder});
  final WorkDownload item;
  final Directory folder;

  @override
  NativeGallery? cachedGallery(int id) => item.gallery?.id == id ? item.gallery : null;

  @override
  Future<NativeGallery> gallery(int id) async => cachedGallery(id) ?? (throw ContentError.galleryNotFound);

  @override
  Future<Uint8List> image(GalleryPage page, {required int galleryID, required bool thumbnail}) async {
    final gallery = cachedGallery(galleryID);
    final index = gallery?.pages.indexOf(page) ?? -1;
    if (gallery == null || index < 0 || index >= item.files.length) throw ContentError.invalidResponse;
    return File('${folder.path}/${item.files[index]}').readAsBytes();
  }

  @override
  Future<GalleryBatch> list(GalleryQuery query, {required int offset, required int count}) async => const GalleryBatch(ids: [], hasMore: false);
}
